import 'dart:ui' show Locale;

import '../state/settings.dart';

/// Locale the UI uses for [language]. "System" uses Chinese only when the
/// device's primary language is Chinese; every other language gets English.
Locale resolveAppLocale(AppLanguage language, List<Locale> platformLocales) {
  const zh = Locale('zh', 'CN');
  const en = Locale('en', 'US');
  return switch (language) {
    AppLanguage.zh => zh,
    AppLanguage.en => en,
    AppLanguage.system =>
      platformLocales.isNotEmpty && platformLocales.first.languageCode == 'zh' ? zh : en,
  };
}
