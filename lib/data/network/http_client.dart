import 'dart:convert';

import 'package:dio/dio.dart';

import '../../domain/parser.dart';

/// SnapFetch 统一 HTTP 客户端（PRD §4.4）：
/// 统一 UA、超时、重试、代理占位；所有请求逐条带 Referer/Cookie 防 403（§4.1 第 5 项）。
abstract final class SnapHttp {
  static Dio? _dio;

  static Dio get dio => _dio ??= Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 15),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36',
        },
        validateStatus: (code) => code != null && code < 500, // 4xx 由解析器归类
        followRedirects: true,
        maxRedirects: 8,
      ));

  /// 组装解析上下文（把捕获的平台 Cookie 注入请求头）。
  static ParseContext context({
    required Map<String, String> cookies,
    String? referer,
    required void Function(String) log,
  }) {
    final dio = SnapHttp.dio;

    Future<PHttpResponse> run(RequestOptions opts) async {
      opts.responseType = ResponseType.bytes;
      final resp = await dio.fetch<List<int>>(opts);
      final body =
          resp.data == null ? '' : utf8.decode(resp.data!, allowMalformed: true);
      return PHttpResponse(
        statusCode: resp.statusCode ?? 0,
        body: body,
        finalUri: resp.realUri,
        headers: resp.headers.map
            .map((k, v) => MapEntry(k.toLowerCase(), v.isEmpty ? '' : v.first)),
      );
    }

    Future<PHttpResponse> get(
      String url, {
      Map<String, String>? headers,
      Map<String, dynamic>? query,
    }) {
      return run(RequestOptions(
        path: url,
        queryParameters: query,
        method: 'GET',
        headers: _merged(headers, referer, cookies),
      ));
    }

    Future<PHttpResponse> post(
      String url, {
      Map<String, dynamic>? jsonBody,
      Map<String, String>? headers,
      Map<String, dynamic>? query,
    }) {
      return run(RequestOptions(
        path: url,
        queryParameters: query,
        method: 'POST',
        data: jsonBody,
        headers: _merged(headers, referer, cookies),
      ));
    }

    return ParseContext(
      cookies: cookies,
      baseHeaders: {'Referer': ?referer},
      httpGet: get,
      httpPost: post,
      log: log,
    );
  }

  static Map<String, dynamic> _merged(
    Map<String, String>? headers,
    String? referer,
    Map<String, String> cookies,
  ) =>
      {
        if (referer != null && !(headers ?? const {}).containsKey('Referer'))
          'Referer': referer,
        if (cookies.isNotEmpty) 'Cookie': _cookieHeader(cookies),
        ...?headers,
      };

  static String _cookieHeader(Map<String, String> cookies) =>
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}
