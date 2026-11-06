import 'dart:convert';
import 'dart:io';

import '../../core/crypto_vault.dart';

/// 一条登录凭证：某平台某账号捕获到的全量 Cookie（PRD §6.6）。
class StoredCredential {
  final String id;
  final String platformId; // 'quark' / 'uc' / ...
  final String label; // 用户备注（如「主号」「小号」）
  final Map<String, String> cookies; // name -> value（全量，含 HttpOnly）
  final DateTime createdAt;

  StoredCredential({
    required this.id,
    required this.platformId,
    required this.label,
    required this.cookies,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'platformId': platformId,
        'label': label,
        'cookies': cookies,
        'createdAt': createdAt.toIso8601String(),
      };

  static StoredCredential fromJson(Map<String, dynamic> j) => StoredCredential(
        id: j['id'] as String,
        platformId: j['platformId'] as String,
        label: j['label'] as String,
        cookies: (j['cookies'] as Map).cast<String, String>(),
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

/// 凭证保险库：DPAPI 加密整包存盘（PRD §2.1 红线 4 / §6.6）。
///
/// - 文件内容 = base64(DPAPI(JSON(所有凭证)))，仅当前 Windows 用户可解
/// - 备份导出/导入复用同一格式：换机导入依赖目标机器与用户（DPAPI 天然隔离，
///   跨机导入需用户口令密钥包，M4 再扩展 AuthCrypto）
abstract class CredentialVault {
  Future<List<StoredCredential>> list();
  Future<void> put(StoredCredential credential);
  Future<void> remove(String id);
  Future<void> clear();
}

class DpapiFileCredentialVault implements CredentialVault {
  final File file;
  Map<String, StoredCredential>? _cache;

  DpapiFileCredentialVault(this.file);

  Future<Map<String, StoredCredential>> _load() async {
    if (_cache != null) return _cache!;
    if (!await file.exists()) {
      _cache = {};
      return _cache!;
    }
    try {
      final cipherB64 = await file.readAsString();
      final plain = DpapiCrypto.unprotectText(cipherB64);
      final list = (jsonDecode(plain) as List)
          .cast<Map<String, dynamic>>()
          .map(StoredCredential.fromJson);
      _cache = {for (final c in list) c.id: c};
    } catch (_) {
      // 解密失败（换用户/文件损坏）：宁可从空开始，绝不让应用起不来
      _cache = {};
    }
    return _cache!;
  }

  Future<void> _flush(Map<String, StoredCredential> cache) async {
    final parent = file.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final json = jsonEncode(cache.values.map((c) => c.toJson()).toList());
    await file.writeAsString(DpapiCrypto.protectText(json));
  }

  @override
  Future<List<StoredCredential>> list() async =>
      (await _load()).values.toList();

  @override
  Future<void> put(StoredCredential credential) async {
    final cache = await _load();
    cache[credential.id] = credential;
    await _flush(cache);
  }

  @override
  Future<void> remove(String id) async {
    final cache = await _load();
    cache.remove(id);
    await _flush(cache);
  }

  @override
  Future<void> clear() async {
    _cache = {};
    await _flush(_cache!);
  }
}
