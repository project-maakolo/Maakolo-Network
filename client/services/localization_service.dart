import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalizationService {
  static final ValueNotifier<String> languageNotifier = ValueNotifier<String>('EN');

// Backward compatibility
  static String get currentLang => languageNotifier.value;

  static const String _langKey = 'selected_language';
  static const List<String> supportedLanguages = ['EN', 'FI', 'RU'];

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    String savedLang = prefs.getString(_langKey) ?? 'EN';

    if (!supportedLanguages.contains(savedLang)) {
      savedLang = 'EN';
    }

    languageNotifier.value = savedLang;
  }

  static Future<void> setLanguage(String lang) async {
    if (supportedLanguages.contains(lang)) {
      languageNotifier.value = lang;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_langKey, lang);
    }
  }

  static Future<void> toggleLanguage() async {
    int currentIndex = supportedLanguages.indexOf(currentLang);
    int nextIndex = (currentIndex + 1) % supportedLanguages.length;
    await setLanguage(supportedLanguages[nextIndex]);
  }

  static String getLanguageButtonText() {
    if (currentLang == 'RU') return 'Язык: Русский';
    if (currentLang == 'FI') return 'Kieli: Suomi';
    return 'Language: English';
  }
}
