import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/core/platform_brand.dart';
import 'package:snapfetch/data/auth/login_rules.dart';
import 'package:snapfetch/ui/widgets/platform_logo.dart';

void main() {
  testWidgets('平台图标：全部注册平台都能渲染', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            for (final id in kLoginRules.keys) PlatformLogo(platformId: id),
          ],
        ),
      ),
    ));
    expect(find.byType(PlatformLogo), findsNWidgets(kLoginRules.length));
    expect(tester.takeException(), isNull);
  });

  testWidgets('取到官方图标时用官方图标，取不到时自绘徽记兜底',
      (WidgetTester tester) async {
    // 本机跑过 tools/fetch-platform-icons.ps1 → 资源存在 → Image；
    // 没跑（仓库默认状态）→ errorBuilder → 色块徽记。两种都必须渲染成功。
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PlatformLogo(platformId: 'quark')),
    ));
    await tester.pump();
    final hasImage = find.byType(Image).evaluate().isNotEmpty;
    final hasBadge = find.byType(PlatformBadge).evaluate().isNotEmpty;
    expect(hasImage || hasBadge, isTrue, reason: '必须有一条可用的渲染路径');
    expect(tester.takeException(), isNull);
  });

  testWidgets('自绘徽记：品牌色块 + 首字，不引用任何第三方图形',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            for (final id in kLoginRules.keys)
              PlatformBadge(platformId: id, size: 40),
          ],
        ),
      ),
    ));
    for (final id in kLoginRules.keys) {
      expect(find.text(brandOf(id).mark), findsOneWidget,
          reason: '$id 的徽记文字应可见');
    }
    expect(find.byType(Image), findsNothing,
        reason: '兜底路径必须是纯代码绘制，不能依赖商标图片');
  });

  testWidgets('未知平台不崩，画中性占位', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PlatformLogo(platformId: 'who_knows', size: 24)),
    ));
    expect(find.text('?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('官方图标一律不入库（商标风险）', () {
    // 品牌表里声明的资源路径必须落在被 .gitignore 排除的目录内，
    // 否则等于把别人的注册商标打进开源分发包。
    for (final e in kPlatformBrands.entries) {
      final asset = e.value.logoAsset;
      if (asset == null) continue;
      expect(asset, startsWith('assets/icons/platforms/'),
          reason: '${e.key} 的图标必须放在不入库的目录');
    }
  });
}
