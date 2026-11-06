import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart'
    as win;
import 'package:uuid/uuid.dart';

import '../../data/auth/credential_vault.dart';
import '../../data/auth/login_rules.dart';

/// 应用内嵌浏览器登录页（PRD §6.6 / D2）。
///
/// - WebView2 环境（userDataFolder）由外部注入并复用，关闭页面即释放 UI，
///   环境本身缓存复用（Cookie 是登录态，不能每次清）
/// - 用户在页面内正常登录（扫码/短信/密码），全程不出应用、不手动复制
/// - 点「完成」→ CDP Network.getCookies 捕获全量 Cookie（含 HttpOnly）→
///   按 [LoginRule.isLoginSuccess] 判定 → DPAPI 加密入库
class LoginPage extends StatefulWidget {
  final LoginRule rule;
  final WebViewEnvironment environment;
  final CredentialVault vault;
  final ValueChanged<StoredCredential> onSaved;

  const LoginPage({
    super.key,
    required this.rule,
    required this.environment,
    required this.vault,
    required this.onSaved,
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  double _progress = 0;
  bool _saving = false;
  String? _error;

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      // CookieManager 需要 Windows 平台实现类型
      final cm = win.WindowsCookieManager.instance(
          webViewEnvironment:
              widget.environment.platform as win.WindowsWebViewEnvironment);
      final cookies = await cm.getCookies(url: WebUri(widget.rule.cookieUrl));
      final map = <String, String>{
        for (final c in cookies)
          if (c.value != null) c.name: c.value!,
      };

      if (!widget.rule.isLoginSuccess(map)) {
        setState(() => _error =
            '未检测到登录态（需要的关键 Cookie 不在）。请在页面里完成登录后再点「完成」。');
        return;
      }

      final cred = StoredCredential(
        id: const Uuid().v4(),
        platformId: widget.rule.platformId,
        label: '账号 ${DateTime.now().toIso8601String().substring(5, 16)}',
        cookies: map,
        createdAt: DateTime.now(),
      );
      await widget.vault.put(cred);
      widget.onSaved(cred);
      if (mounted) Navigator.of(context).pop(cred);
    } catch (e) {
      setState(() => _error = '捕获 Cookie 失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text('登录 · ${widget.rule.displayName}'),
          centerTitle: true,
          actions: [
            TextButton.icon(
              onPressed: _saving ? null : _finish,
              icon: const Icon(Icons.download_done),
              label: const Text('完成'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          children: [
            if (_progress < 1.0)
              LinearProgressIndicator(value: _progress, minHeight: 2),
            if (_error != null)
              Material(
                color: theme.colorScheme.errorContainer,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.warning_amber_rounded),
                  title: Text(_error!, style: theme.textTheme.bodySmall),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _error = null),
                  ),
                ),
              ),
            Expanded(
              child: InAppWebView(
                webViewEnvironment: widget.environment,
                initialUrlRequest: URLRequest(url: WebUri(widget.rule.loginUrl)),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  userAgent:
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                      '(KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36',
                ),
                onPermissionRequest: (controller, request) async {
                  // 登录页可能申请摄像头（扫码）/通知：登录窗口内按需放行，
                  // 仅作用于本次会话，不影响系统（PRD §6.6 安全约束）。
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStart: (_, _) => setState(() {
                  _error = null;
                  _progress = 0;
                }),
                onProgressChanged: (_, p) => setState(() => _progress = p / 100),
                onLoadStop: (_, _) => setState(() => _progress = 1.0),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
