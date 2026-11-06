import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/credential_vault.dart';
import '../../data/auth/login_rules.dart';
import '../../domain/parser.dart';
import '../../providers.dart';
import '../widgets/page_scaffold.dart';
import 'cloud_drive_page.dart';
import 'login_page.dart';

/// 账号页（PRD §4.1 第 8 项 / §6.6）：平台卡片 + 多账号管理。
///
/// - 需要 Cookie 的平台显示「应用内登录」
/// - 免登录平台明确标注「免登录可用」（红线 3：登录不得成为全局前置条件）
/// - 凭证经 DPAPI 加密落盘，仅本机可解
///
/// ★ 数据目录统一走 [appDirProvider]（含三级兜底），不再自行调用
///   getApplicationSupportDirectory —— 后者用 exe 元数据拼目录，实测 errno 5。
class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key});

  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage> {
  CredentialVault? _vault;
  WebViewEnvironment? _env;
  List<StoredCredential> _credentials = [];
  String? _message;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final dir = await ref.read(appDirProvider.future);
      final vault = DpapiFileCredentialVault(
          File('${dir.path}${Platform.pathSeparator}credentials.bin'));

      // WebView2 环境：userDataFolder 收敛在应用数据目录，Cookie 即登录态，跨登录复用
      String? webViewProblem;
      try {
        final version = await WebViewEnvironment.getAvailableVersion();
        if (version == null) {
          webViewProblem =
              '本机未安装 WebView2 Runtime，应用内登录暂不可用。安装包内附 MicrosoftEdgeWebview2Setup.exe，安装后重启即可。';
        }
      } catch (e) {
        webViewProblem = 'WebView2 检测失败：$e';
      }

      WebViewEnvironment? env;
      if (webViewProblem == null) {
        try {
          // ★ 必须 await create()：只 new 一个环境对象不会把 settings 传给原生，
          //   WebView2 会退回默认 userDataFolder = <exe 同目录>\SnapFetch.exe.WebView2
          //   （实测把 Cookies/Login Data 写进了程序目录，差点被打进分发包）。
          env = await WebViewEnvironment.create(
            settings: WebViewEnvironmentSettings(
              userDataFolder: '${dir.path}${Platform.pathSeparator}webview2',
            ),
          );
        } catch (e) {
          webViewProblem = 'WebView2 环境创建失败：$e';
        }
      }

      if (!mounted) return;
      setState(() {
        _vault = vault; // 即使 WebView 不可用，凭证读取仍可用
        _env = env;
        _message = webViewProblem;
      });
      await _reload();
    } catch (e) {
      if (mounted) setState(() => _message = '数据目录初始化失败：$e');
    }
  }

  Future<void> _reload() async {
    if (_vault == null) return;
    setState(() => _credentials = []);
    _credentials = await _vault!.list();
    if (mounted) setState(() {});
  }

  Future<void> _startLogin(LoginRule rule) async {
    if (_env == null || _vault == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LoginPage(
        rule: rule,
        environment: _env!,
        vault: _vault!,
        onSaved: (_) {},
      ),
    ));
    await _reload();
  }

  /// 进入云盘浏览（浏览自己账号里的文件）。
  Future<void> _openDrive(LoginRule rule, StoredCredential account) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CloudDrivePage(
        platformId: rule.platformId,
        platformName: rule.displayName,
        accountLabel: account.label,
      ),
    ));
    await _reload();
  }

  Future<void> _remove(StoredCredential c) async {
    await _vault?.remove(c.id);
    await _reload();
  }

  @override
  void dispose() {
    _env?.dispose(); // WebViewEnvironment.dispose()
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 凭证库可用 = 数据目录正常；WebView 不可用只影响「应用内登录」按钮
    final dirOk = _vault != null;
    return PageScaffold(
      title: '账号',
      subtitle: null,
      child: ListView(
        children: [
          if (_message != null)
            Card(
              color: dirOk
                  ? theme.colorScheme.tertiaryContainer // 提示（如缺 WebView2）
                  : theme.colorScheme.errorContainer, // 错误（数据目录不可用）
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(dirOk ? Icons.info_outline : Icons.error_outline,
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_message!, style: theme.textTheme.bodyMedium),
                    ),
                  ],
                ),
              ),
            ),
          for (final rule in kLoginRules.values) _platformCard(rule),
        ],
      ),
    );
  }

  Widget _platformCard(LoginRule rule) {
    final theme = Theme.of(context);
    final accounts =
        _credentials.where((c) => c.platformId == rule.platformId).toList();
    final loggedIn = accounts.isNotEmpty && rule.kind == PlatformKind.netdisk;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        // ★ 已登录的网盘：点击卡片进入「云盘浏览」（对齐官方「网盘」页）
        onTap: loggedIn ? () => _openDrive(rule, accounts.first) : null,
        leading: Icon(
          rule.required ? Icons.lock_outline : Icons.lock_open,
          color: rule.required
              ? theme.colorScheme.primary
              : theme.colorScheme.outline,
        ),
        title: Row(
          children: [
            Text(rule.displayName),
            if (loggedIn) ...[
              const SizedBox(width: 8),
              Text('点击浏览文件',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary)),
              const Spacer(),
              Icon(Icons.chevron_right,
                  size: 18, color: theme.colorScheme.outline),
            ],
          ],
        ),
        subtitle: accounts.isEmpty
            ? Text(rule.required ? '未登录 · 解析需登录' : '免登录可用',
                style: theme.textTheme.bodySmall)
            : Wrap(
                spacing: 6,
                children: [
                  for (final a in accounts)
                    InputChip(
                      label: Text(a.label, style: theme.textTheme.labelSmall),
                      onDeleted: () => _remove(a),
                    ),
                ],
              ),
        trailing: FilledButton.tonal(
          onPressed: _env == null ? null : () => _startLogin(rule),
          child: Text(accounts.isEmpty ? '登录' : '添加'),
        ),
      ),
    );
  }
}
