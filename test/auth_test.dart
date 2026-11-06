import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/core/crypto_vault.dart';
import 'package:snapfetch/data/auth/credential_vault.dart';
import 'package:snapfetch/data/auth/login_rules.dart';
import 'package:snapfetch/domain/parser.dart';

void main() {
  group('DpapiCrypto（Windows DPAPI）', () {
    test('加解密往返', () {
      const plain = '{"cookies":{"__pus":"secret-value"}}';
      final cipher = DpapiCrypto.protectText(plain);
      expect(cipher, isNot(contains('secret')), reason: '密文不得包含明文片段');
      expect(DpapiCrypto.unprotectText(cipher), plain);
    });

    test('中文与空值往返', () {
      const plain = '夸克网盘 主账号 🔑 空:';
      final cipher = DpapiCrypto.protectText(plain);
      expect(DpapiCrypto.unprotectText(cipher), plain);
    });

    test('每次加密结果不同（DPAPI 含随机熵）', () {
      const plain = 'same-input';
      expect(DpapiCrypto.protectText(plain),
          isNot(DpapiCrypto.protectText(plain)));
    });

    test('空串往返不抛异常', () {
      expect(DpapiCrypto.protectText(''), '');
      expect(DpapiCrypto.unprotectText(''), '');
    });
  });

  group('DpapiFileCredentialVault', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sf_vault');
      file = File('${dir.path}${Platform.pathSeparator}credentials.bin');
    });

    tearDown(() async => dir.delete(recursive: true));

    test('落盘文件不含明文', () async {
      final vault = DpapiFileCredentialVault(file);
      await vault.put(StoredCredential(
        id: 'c1',
        platformId: 'quark',
        label: '主号',
        cookies: {'__pus': 'top-secret-token'},
        createdAt: DateTime(2026, 11, 4),
      ));

      final raw = await file.readAsString();
      expect(raw, isNot(contains('top-secret')), reason: '文件里必须是 DPAPI 密文');
      expect(raw, isNot(contains('quark')), reason: '连元数据也不应可见');
    });

    test('保存-重开实例-读取（模拟应用重启）', () async {
      final vault1 = DpapiFileCredentialVault(file);
      await vault1.put(StoredCredential(
        id: 'c1',
        platformId: 'uc',
        label: 'UC 主号',
        cookies: {'__pus': 'a', 'kps': 'b'},
        createdAt: DateTime(2026, 11, 4),
      ));

      final vault2 = DpapiFileCredentialVault(file); // 新实例 = 重启
      final list = await vault2.list();
      expect(list.single.platformId, 'uc');
      expect(list.single.cookies['__pus'], 'a');
    });

    test('删除与清空', () async {
      final vault = DpapiFileCredentialVault(file);
      await vault.put(StoredCredential(
          id: 'a', platformId: 'quark', label: 'x', cookies: {}, createdAt: DateTime.now()));
      await vault.put(StoredCredential(
          id: 'b', platformId: 'uc', label: 'y', cookies: {}, createdAt: DateTime.now()));
      await vault.remove('a');
      expect((await vault.list()).length, 1);
      await vault.clear();
      expect(await vault.list(), isEmpty);
    });

    test('损坏文件回退为空，不抛异常', () async {
      await file.writeAsString('not-a-valid-cipher');
      final vault = DpapiFileCredentialVault(file);
      expect(await vault.list(), isEmpty, reason: '解密失败宁可从空开始');
    });
  });

  group('LoginRules（红线 3：免登录不得强制登录）', () {
    test('3 家网盘 + 2 家视频平台规则齐备', () {
      expect(
        kLoginRules.keys,
        containsAll(['quark', 'uc', 'pan123', 'douyin', 'xiaohongshu']),
      );
      expect(kLoginRules.keys, hasLength(5));
    });

    test('视频平台必须免登录可用（红线 R1）', () {
      for (final id in ['douyin', 'xiaohongshu']) {
        expect(kLoginRules[id]!.required, isFalse,
            reason: '$id 免登录即可直出直链，不能把登录做成前置条件');
        expect(kLoginRules[id]!.kind, PlatformKind.video);
      }
    });

    test('必登录平台的规则完整（URL + 成功判定）', () {
      for (final rule in kLoginRules.values.where((r) => r.required)) {
        expect(rule.loginUrl, startsWith('https://'), reason: '${rule.platformId} 登录页须 HTTPS 官方域名');
        expect(rule.cookieUrl, isNotEmpty);
        expect(rule.successCookieNames, isNotEmpty,
            reason: '${rule.platformId} 必须有关键 Cookie 判定，否则无法确认登录');
      }
    });

    test('123 云盘：登录态在 localStorage token，不在 Cookie', () {
      // pan123 免登录可解析分享，但取链/浏览需 token
      final rule = kLoginRules['pan123']!;
      expect(rule.required, isFalse);
      expect(rule.tokenKey, isNotNull, reason: '123 必须配置 token 键名');
      expect(rule.tokenJsExpression, isNotNull, reason: '需要从 localStorage 取值');
      // 有 token 即登录成功
      expect(rule.isLoginSuccess({rule.tokenKey!: 'jwt-value'}), isTrue);
      // 空凭证不算
      expect(rule.isLoginSuccess(const {}), isFalse);
    });

    test('免登录且无判定名的平台：抓到任意 Cookie 即算', () {
      for (final rule in kLoginRules.values
          .where((r) => !r.required && r.successCookieNames.isEmpty)) {
        expect(rule.isLoginSuccess(const {}),
            isFalse, reason: '没抓到任何 Cookie 不能算登录成功');
        expect(rule.isLoginSuccess(const {'any': '1'}), isTrue,
            reason: '${rule.platformId} 无名单时非空即算');
      }
    });

    test('成功判定不区分大小写', () {
      const rule = LoginRule(
        platformId: 'x',
        displayName: 'X',
        loginUrl: 'https://x/',
        cookieUrl: 'https://x/',
        successCookieNames: ['__PUS'],
      );
      expect(rule.isLoginSuccess({'__pus': 'v'}), isTrue);
    });
  });
}
