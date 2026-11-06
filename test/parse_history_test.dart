import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/core/parse_history.dart';
import 'package:snapfetch/data/auth/login_rules.dart';
import 'package:snapfetch/core/platform_brand.dart';

ParseHistoryEntry _e(String url, {String passcode = '', bool ok = true, int minute = 0}) =>
    ParseHistoryEntry(
      id: '$url-$minute',
      url: url,
      passcode: passcode,
      platformId: 'quark',
      platformName: '夸克网盘',
      summary: ok ? '3 个文件' : '提取码错误',
      ok: ok,
      at: DateTime(2026, 11, 6, 10).add(Duration(minutes: minute)),
    );

void main() {
  group('解析历史（内存实现）', () {
    test('按时间倒序返回', () async {
      final store = MemoryParseHistoryStore();
      await store.record(_e('a', minute: 1));
      await store.record(_e('b', minute: 5));
      await store.record(_e('c', minute: 2));
      final all = await store.all();
      expect(all.map((e) => e.url).toList(), ['b', 'c', 'a']);
    });

    test('同链接重复解析不新增条目，只把时间提到最新', () async {
      final store = MemoryParseHistoryStore();
      await store.record(_e('same', minute: 1, ok: false));
      await store.record(_e('same', minute: 9, ok: true));
      final all = await store.all();
      expect(all, hasLength(1));
      expect(all.single.ok, isTrue, reason: '最新一次结果应覆盖旧结果');
    });

    test('同链接不同提取码算两条', () async {
      final store = MemoryParseHistoryStore();
      await store.record(_e('same', minute: 1));
      await store.record(_e('same', passcode: 'abcd', minute: 2));
      expect(await store.all(), hasLength(2));
    });

    test('超出上限丢弃最旧的', () async {
      final store = MemoryParseHistoryStore();
      for (var i = 0; i < FileParseHistoryStore.maxEntries + 20; i++) {
        await store.record(_e('u$i', minute: i));
      }
      final all = await store.all();
      expect(all, hasLength(FileParseHistoryStore.maxEntries));
      expect(all.first.url, 'u${FileParseHistoryStore.maxEntries + 19}',
          reason: '最新一条必须保留');
    });

    test('删除与清空', () async {
      final store = MemoryParseHistoryStore();
      await store.record(_e('x', minute: 1));
      await store.record(_e('y', minute: 2));
      await store.remove('x-1');
      expect(await store.all(), hasLength(1));
      await store.clear();
      expect(await store.all(), isEmpty);
    });
  });

  group('解析历史（JSON 落盘）', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('sf_history');
      file = File('${dir.path}${Platform.pathSeparator}parse_history.json');
    });
    tearDown(() async => dir.delete(recursive: true));

    test('保存-重开实例-读取（模拟应用重启）', () async {
      await FileParseHistoryStore(file).record(_e('persist-me', minute: 3));
      final reopened = await FileParseHistoryStore(file).all();
      expect(reopened.single.url, 'persist-me');
      expect(reopened.single.summary, '3 个文件');
    });

    test('损坏文件回退为空，不抛异常', () async {
      await file.writeAsString('{not json');
      expect(await FileParseHistoryStore(file).all(), isEmpty);
    });
  });

  group('平台品牌标识', () {
    test('每个登录规则平台都有品牌（否则账号页图标会退化成灰块）', () {
      for (final id in kLoginRules.keys) {
        expect(kPlatformBrands.containsKey(id), isTrue,
            reason: '$id 缺品牌色：新增平台要同时补 kPlatformBrands');
        expect(kPlatformBrands[id]!.mark, isNotEmpty);
      }
    });

    test('未知平台回落中性标识，不抛', () {
      final b = brandOf('nonexistent');
      expect(b.mark, isNotEmpty);
    });
  });
}
