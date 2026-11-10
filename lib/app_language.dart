import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage {
  german('de', 'Deutsch'),
  english('en', 'English'),
  albanian('sq', 'Shqip'),
  armenian('hy', 'Հայերեն'),
  azerbaijani('az', 'Azərbaycanca'),
  basque('eu', 'Euskara'),
  belarusian('be', 'Беларуская'),
  bosnian('bs', 'Bosanski'),
  bulgarian('bg', 'Български'),
  catalan('ca', 'Català'),
  croatian('hr', 'Hrvatski'),
  czech('cs', 'Čeština'),
  danish('da', 'Dansk'),
  dutch('nl', 'Nederlands'),
  estonian('et', 'Eesti'),
  faroese('fo', 'Føroyskt'),
  finnish('fi', 'Suomi'),
  french('fr', 'Français'),
  galician('gl', 'Galego'),
  georgian('ka', 'ქართული'),
  greek('el', 'Ελληνικά'),
  hungarian('hu', 'Magyar'),
  icelandic('is', 'Íslenska'),
  irish('ga', 'Gaeilge'),
  italian('it', 'Italiano'),
  kazakh('kk', 'Қазақша'),
  latvian('lv', 'Latviešu'),
  lithuanian('lt', 'Lietuvių'),
  luxembourgish('lb', 'Lëtzebuergesch'),
  macedonian('mk', 'Македонски'),
  maltese('mt', 'Malti'),
  montenegrin('cnr', 'Crnogorski'),
  norwegian('nb', 'Norsk bokmål'),
  nynorsk('nn', 'Norsk nynorsk'),
  polish('pl', 'Polski'),
  portuguese('pt', 'Português', region: 'PT'),
  romanian('ro', 'Română'),
  romansh('rm', 'Rumantsch'),
  russian('ru', 'Русский'),
  scottishGaelic('gd', 'Gàidhlig'),
  serbian('sr', 'Српски'),
  slovak('sk', 'Slovenčina'),
  slovenian('sl', 'Slovenščina'),
  spanish('es', 'Español'),
  swedish('sv', 'Svenska'),
  turkish('tr', 'Türkçe'),
  ukrainian('uk', 'Українська'),
  welsh('cy', 'Cymraeg');

  const AppLanguage(this.code, this.nativeName, {this.region});

  final String code;
  final String nativeName;
  final String? region;

  Locale get locale => Locale(code, region);
}

class AppLanguageController extends ValueNotifier<AppLanguage> {
  AppLanguageController() : super(AppLanguage.german);

  static const _preferenceKey = 'app_language';
  static final _parameterPattern = RegExp(r'\{(\w+)\}');

  Map<String, String> _messages = const {};
  Future<bool> _lastChange = Future.value(true);

  Future<void> load() async {
    try {
      final code = await SharedPreferencesAsync().getString(_preferenceKey);
      final language = AppLanguage.values.firstWhere(
        (language) => language.code == code,
        orElse: () => AppLanguage.german,
      );
      await _loadLanguage(language);
    } catch (_) {
      _messages = const {};
      value = AppLanguage.german;
    }
  }

  Future<bool> change(AppLanguage language) {
    _lastChange = _lastChange.then((_) async {
      if (language == value) return true;
      try {
        await _loadLanguage(language);
      } catch (_) {
        return false;
      }

      try {
        await SharedPreferencesAsync().setString(_preferenceKey, language.code);
      } catch (_) {
        // Keep the selected language active for the current session.
      }
      return true;
    });
    return _lastChange;
  }

  Future<void> _loadLanguage(AppLanguage language) async {
    if (language == AppLanguage.german || language == AppLanguage.english) {
      _messages = const {};
    } else {
      final source = await rootBundle.loadString(
        'assets/l10n/${language.code}.json',
      );
      _messages = Map<String, String>.from(jsonDecode(source) as Map);
    }
    value = language;
  }

  String translate(
    String german,
    String english, [
    Map<String, Object?> parameters = const {},
  ]) {
    final message = value == AppLanguage.german
        ? german
        : _messages[english] ?? english;
    if (parameters.isEmpty) return message;
    return message.replaceAllMapped(
      _parameterPattern,
      (match) => parameters.containsKey(match[1])
          ? parameters[match[1]].toString()
          : match[0]!,
    );
  }
}

final appLanguageController = AppLanguageController();

String tr(
  String german,
  String english, [
  Map<String, Object?> parameters = const {},
]) => appLanguageController.translate(german, english, parameters);

class AppLanguageScope extends InheritedNotifier<AppLanguageController> {
  AppLanguageScope({super.key, required super.child})
    : super(notifier: appLanguageController);

  static void watch(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<AppLanguageScope>();
  }
}

Future<void> chooseAppLanguage(BuildContext context) async {
  final selected = appLanguageController.value;
  final language = await showModalBottomSheet<AppLanguage>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 0.8,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(
                tr('Sprache auswählen', 'Select language'),
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: AppLanguage.values.length,
                itemBuilder: (context, index) {
                  final option = AppLanguage.values[index];
                  return ListTile(
                    title: Text(option.nativeName),
                    selected: option == selected,
                    trailing: option == selected
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(option),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (language == null || !context.mounted) return;
  final changed = await appLanguageController.change(language);
  if (!changed && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          tr(
            'Sprache konnte nicht geladen werden.',
            'Could not load language.',
          ),
        ),
      ),
    );
  }
}
