import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snapfetch/core/platform_brand.dart';
import 'package:snapfetch/data/auth/login_rules.dart';
import 'package:snapfetch/ui/widgets/platform_logo.dart';

void main() {
  testWidgets('平台图标：全部注册平台都能渲染（品牌色块 + 徽记）',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            for (final id in kLoginRules.keys)
              PlatformLogo(platformId: id, size: 40),
          ],
        ),
      ),
    ));

    // 每个平台一个色块，且各自的字都画出来
    expect(find.byType(PlatformLogo), findsNWidgets(kLoginRules.length));
    for (final id in kLoginRules.keys) {
      expect(find.text(brandOf(id).mark), findsOneWidget,
          reason: '$id 的徽记文字应可见');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('平台图标：不用官方 logo 图片（避免商标风险）',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PlatformLogo(platformId: 'quark')),
    ));
    expect(find.byType(Image), findsNothing,
        reason: '图标必须是本地绘制的品牌色块，不能引用官方位图资源');
    expect(find.byType(RoundedRectangleBorder), findsNothing);
  });

  testWidgets('未知平台不崩，画中性占位', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PlatformLogo(platformId: 'who_knows', size: 24)),
    ));
    expect(find.text('?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
