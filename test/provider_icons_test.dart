import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:token_bar/ui/widgets/provider_badge.dart';
import 'package:tokenbar_core/tokenbar_core.dart';

/// Guards against provider renames or new providers silently falling back to
/// the initial-letter badge: every registered provider must either have a logo
/// or be listed in [providerIconFallbackIds].
void main() {
  final registryIds = ProviderRegistry.instance.all.map((p) => p.id).toSet();
  final iconDir = Directory('assets/provider_icons');
  final svgFiles = iconDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.svg'))
      .toList();
  final svgIds = {
    for (final f in svgFiles) f.uri.pathSegments.last.replaceFirst(RegExp(r'\.svg$'), ''),
  };

  test('every registered provider has a logo or an explicit fallback', () {
    final missing =
        registryIds
            .where((id) => !providerIconIds.contains(id) && !providerIconFallbackIds.contains(id))
            .toList()
          ..sort();
    expect(
      missing,
      isEmpty,
      reason: 'add an SVG to assets/provider_icons or list it as a fallback',
    );
  });

  test('logo and fallback lists do not overlap and only name registered providers', () {
    expect(providerIconIds.intersection(providerIconFallbackIds), isEmpty);
    expect(providerIconIds.difference(registryIds), isEmpty, reason: 'stale logo ids');
    expect(providerIconFallbackIds.difference(registryIds), isEmpty, reason: 'stale fallback ids');
    expect(providerColoredIconIds.difference(providerIconIds), isEmpty);
  });

  test('logo ids match the SVG files on disk', () {
    expect(svgIds, providerIconIds);
    for (final id in providerIconIds) {
      expect(File('assets/provider_icons/$id.svg').existsSync(), isTrue, reason: id);
    }
  });

  test('bundled logos avoid features flutter_svg cannot draw', () {
    const unsupported = ['<style', 'class=', '<filter', '<text', '<image', 'data:image', '<mask'];
    for (final f in svgFiles) {
      final text = f.readAsStringSync();
      final name = f.uri.pathSegments.last;
      expect(f.lengthSync(), lessThan(60 * 1024), reason: name);
      for (final token in unsupported) {
        expect(text.contains(token), isFalse, reason: '$name contains $token');
      }
    }
  });

  testWidgets('bundled logos are listed in the asset manifest', (tester) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final id in providerIconIds) {
      expect(manifest.listAssets(), contains('assets/provider_icons/$id.svg'), reason: id);
    }
  });
}
