import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/credential_vault.dart';
import '../../data/auth/login_rules.dart';
import '../../domain/parser.dart';
import '../../providers.dart';
import '../widgets/page_scaffold.dart';
import '../widgets/platform_logo.dart';
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
        title: Row(
          children: [
            PlatformLogo(platformId: rule.platformId, size: 34),
            const SizedBox(width: 10),
            Text(rule.displayName),
            const SizedBox(width: 8),
            Icon(
              rule.required ? Icons.lock_outline : Icons.lock_open,
              size: 15,
              color: rule.required
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
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
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (accounts.isEmpty)
              Text(rule.required ? '未登录 · 解析需登录' : '免登录可用',
                  style: theme.textTheme.bodySmall)
            else
              Wrap(
                spacing: 6,
                children: [
                  for (final a in accounts)
                    InputChip(
                      label: Text(a.label, style: theme.textTheme.labelSmall),
                      onDeleted: () => _remove(a),
                    ),
                ],
              ),
            // 网盘账号：昵称 + 容量条（对齐手机版夸克卡片）
            if (loggedIn) _AccountStatView(platformId: rule.platformId),
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

/// 账号概览：昵称 + 「已用 x / 总量」容量进度条。
///
/// 只在登录态下请求；拉不到（接口改版/网络问题）就整块不显示，不留空占位。
class _AccountStatView extends ConsumerWidget {
  final String platformId;

  const _AccountStatView({required this.platformId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final stat = ref.watch(accountStatProvider(platformId));
    final s = stat.value;
    if (s == null) return const SizedBox(height: 2);

    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (s.nickname != null)
            Text(s.nickname!, style: theme.textTheme.titleSmall),
          if (s.used != null && s.total != null) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: (s.ratio ?? 0).clamp(0.0, 1.0),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 3),
            Text('已用 ${_fmt(s.used!)} / ${_fmt(s.total!)}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }

  static String _fmt(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    // 整数就不带小数（672 MB 比 672.0 MB 干净）
    final s = v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '$s ${units[i]}';
  }
}
