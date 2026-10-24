import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_bar/app/theme.dart';
import 'package:token_bar/ui/widgets/provider_badge.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

void main() {
  String initialOf(String providerId) {
    final name = ProviderRegistry.instance.byId(providerId)!.displayName;
    return name.characters.first.toUpperCase();
  }

  Future<void> pumpBadges(WidgetTester tester, List<String> ids, {required ThemeData theme}) {
    return tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Row(children: [for (final id in ids) ProviderBadge(providerId: id, size: 32)]),
        ),
      ),
    );
  }

  for (final entry in {'light': AppTheme.light(), 'dark': AppTheme.dark()}.entries) {
    testWidgets('${entry.key}: a provider with a logo renders an SvgPicture', (tester) async {
      await pumpBadges(tester, const ['codex', 'claude', 'openai'], theme: entry.value);
      await tester.pump();

      expect(find.byType(SvgPicture), findsNWidgets(3));
      expect(find.text(initialOf('codex')), findsNothing);
    });

    testWidgets('${entry.key}: a provider without a logo shows its initial', (tester) async {
      await pumpBadges(tester, const ['ibmbob'], theme: entry.value);
      await tester.pump();

      expect(find.byType(SvgPicture), findsNothing);
      expect(find.text(initialOf('ibmbob')), findsOneWidget);
    });
  }

  testWidgets('a silhouette logo is recoloured, a coloured logo is not', (tester) async {
    await pumpBadges(tester, const ['cursor', 'claude'], theme: AppTheme.light());
    await tester.pump();

    final svgs = tester.widgetList<SvgPicture>(find.byType(SvgPicture)).toList();
    expect(svgs[0].colorFilter, isNotNull, reason: 'cursor is a single-colour silhouette');
    expect(svgs[1].colorFilter, isNull, reason: 'claude keeps its brand colour');
  });
}
