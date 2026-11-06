import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// CRYPTPROTECT_UI_FORBIDDEN：禁止 DPAPI 弹任何 UI（后台加解密必须）。
/// win32 包未导出该常量，按 win_crypt.h 定义补齐。
const int kCryptProtectUiForbidden = 0x1;

/// Windows DPAPI 封装（PRD §6.6：凭证本地加密，仅本机可解）。
///
/// 使用 CryptProtectData / CryptUnprotectData（crypt32），
/// 绑定当前 Windows 用户 —— 换机器 / 换用户均无法解密，
/// 这是「凭证只存本机、不上传」承诺的底层保证。
abstract final class DpapiCrypto {
  /// 加密：明文字节 -> DPAPI 密文（含描述头，解密时可校验来源）。
  static Uint8List protect(List<int> plain, {String description = 'SnapFetch credentials'}) {
    if (plain.isEmpty) return Uint8List(0);
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();
    final desc = description.toNativeUtf16();
    final inPtr = calloc<Uint8>(plain.length);
    try {
      inPtr.asTypedList(plain.length).setAll(0, plain);
      inBlob.ref.cbData = plain.length;
      inBlob.ref.pbData = inPtr;

      final ok = CryptProtectData(
        inBlob,
        desc,
        nullptr,
        nullptr,
        nullptr,
        kCryptProtectUiForbidden,
        outBlob,
      );
      if (ok == 0) {
        throw StateError('CryptProtectData failed: ${GetLastError()}');
      }
      final size = outBlob.ref.cbData;
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(size));
    } finally {
      if (outBlob.ref.pbData != nullptr) {
        LocalFree(outBlob.ref.pbData);
      }
      calloc.free(inPtr);
      calloc.free(inBlob);
      calloc.free(outBlob);
      calloc.free(desc);
    }
  }

  /// 解密：DPAPI 密文 -> 明文字节。
  static Uint8List unprotect(Uint8List cipher) {
    if (cipher.isEmpty) return Uint8List(0);
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();
    final descPtr = calloc<Pointer<Utf16>>();
    final inPtr = calloc<Uint8>(cipher.length);
    try {
      inPtr.asTypedList(cipher.length).setAll(0, cipher);
      inBlob.ref.cbData = cipher.length;
      inBlob.ref.pbData = inPtr;

      final ok = CryptUnprotectData(
        inBlob,
        descPtr,
        nullptr,
        nullptr,
        nullptr,
        kCryptProtectUiForbidden,
        outBlob,
      );
      if (ok == 0) {
        throw StateError('CryptUnprotectData failed: ${GetLastError()}');
      }
      final size = outBlob.ref.cbData;
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(size));
    } finally {
      if (outBlob.ref.pbData != nullptr) LocalFree(outBlob.ref.pbData);
      if (descPtr.value != nullptr) LocalFree(descPtr.value);
      calloc.free(inPtr);
      calloc.free(inBlob);
      calloc.free(outBlob);
      calloc.free(descPtr);
    }
  }

  /// 便捷封装：加密 UTF-8 字符串 -> base64。
  static String protectText(String plain) =>
      base64Encode(protect(utf8.encode(plain)));

  /// 便捷封装：base64 密文 -> UTF-8 字符串。
  static String unprotectText(String cipherB64) =>
      utf8.decode(unprotect(base64Decode(cipherB64)));
}
