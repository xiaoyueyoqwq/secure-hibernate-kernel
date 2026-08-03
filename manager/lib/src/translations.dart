import 'dart:convert';

import 'package:flutter/services.dart';

enum AppLanguage {
  enUS('en-US'),
  zhCN('zh-CN'),
  zhTW('zh-TW');

  const AppLanguage(this.code);

  final String code;

  static AppLanguage fromLocale(
    String languageCode,
    String? countryCode, [
    String? scriptCode,
  ]) {
    if (languageCode.toLowerCase() != 'zh') return AppLanguage.enUS;
    if (scriptCode?.toLowerCase() == 'hant') return AppLanguage.zhTW;
    final region = countryCode?.toUpperCase();
    return region == 'TW' || region == 'HK' || region == 'MO'
        ? AppLanguage.zhTW
        : AppLanguage.zhCN;
  }
}

class TranslationCatalog {
  TranslationCatalog(this._dictionaries);

  final Map<AppLanguage, Map<String, dynamic>> _dictionaries;

  static Future<TranslationCatalog> load() async {
    final entries = await Future.wait(
      AppLanguage.values.map((language) async {
        final source = await rootBundle.loadString(
          'assets/i18n/${language.code}.json',
        );
        return MapEntry(
          language,
          jsonDecode(source) as Map<String, dynamic>,
        );
      }),
    );
    return TranslationCatalog(Map.fromEntries(entries));
  }

  AppMessages messages(AppLanguage language) =>
      AppMessages(_dictionaries[language]!);
}

class AppMessages {
  const AppMessages(this._dictionary);

  final Map<String, dynamic> _dictionary;

  dynamic _resolve(String path) {
    dynamic value = _dictionary;
    for (final segment in path.split('.')) {
      if (value is! Map<String, dynamic> || !value.containsKey(segment)) {
        throw StateError('Missing translation key: $path');
      }
      value = value[segment];
    }
    return value;
  }

  String text(String path, [Map<String, Object> values = const {}]) {
    var message = _resolve(path) as String;
    for (final entry in values.entries) {
      message = message.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return message;
  }

  List<String> list(String path) =>
      (_resolve(path) as List<dynamic>).cast<String>();
}
