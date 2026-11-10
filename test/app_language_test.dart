import 'dart:convert';

import 'package:atool_app/app_language.dart';
import 'package:atool_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _UnavailablePathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'all translated languages bundle the same messages and parameters',
    () async {
      final parameters = RegExp(r'\{\w+\}');
      Set<String>? keys;
      for (final language in AppLanguage.values) {
        if (language == AppLanguage.german || language == AppLanguage.english) {
          continue;
        }
        final source = await rootBundle.loadString(
          'assets/l10n/${language.code}.json',
        );
        final messages = Map<String, String>.from(jsonDecode(source) as Map);
        expect(messages, isNotEmpty, reason: language.nativeName);
        keys ??= messages.keys.toSet();
        expect(messages.keys.toSet(), keys, reason: language.nativeName);
        for (final entry in messages.entries) {
          final reason = '${language.nativeName}: ${entry.key}';
          expect(entry.value.trim(), isNotEmpty, reason: reason);
          expect(
            parameters.allMatches(entry.value).map((match) => match[0]),
            unorderedEquals(
              parameters.allMatches(entry.key).map((match) => match[0]),
            ),
            reason: reason,
          );
        }
      }
    },
  );

  testWidgets('settings switch language and preserve the selection', (
    tester,
  ) async {
    final previousPlatform = SharedPreferencesAsyncPlatform.instance;
    final previousPathProvider = PathProviderPlatform.instance;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({'app_language': 'en'});
    PathProviderPlatform.instance = _UnavailablePathProvider();
    addTearDown(() async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      await appLanguageController.load();
      SharedPreferencesAsyncPlatform.instance = previousPlatform;
      PathProviderPlatform.instance = previousPathProvider;
    });
    FlutterSecureStorage.setMockInitialValues({'device_uuid': 'test-device'});
    PackageInfo.setMockInitialValues(
      appName: 'ATool',
      packageName: 'de.adleraufmasse.atool',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    await appLanguageController.load();
    expect(appLanguageController.value, AppLanguage.english);
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const polishAsset = 'assets/l10n/pl.json';
    final polishData = await tester.runAsync(
      () => rootBundle.load(polishAsset),
    );
    rootBundle.evict(polishAsset);
    addTearDown(() => rootBundle.evict(polishAsset));
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      (message) async =>
          const StringCodec().decodeMessage(message) == polishAsset
          ? polishData
          : null,
    );
    await tester.pumpWidget(
      AppLanguageScope(
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const InfoLicensePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    await tester.ensureVisible(find.text('Language'));
    await tester.tap(find.text('Language'));
    await tester.pumpAndSettle();

    final polish = find.text('Polski');
    await tester.scrollUntilVisible(
      polish,
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(polish);
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Could not load language.'), findsNothing);
    expect(appLanguageController.value, AppLanguage.polish);
    expect(find.text('Ustawienia'), findsOneWidget);
    expect(find.text('Język'), findsOneWidget);
    final restored = AppLanguageController();
    await restored.load();
    expect(restored.value, AppLanguage.polish);
    expect(
      restored.translate('Gespeichert in: {folder}', 'Saved to: {folder}', {
        'folder': 'DXF',
      }),
      'Zapisano w: DXF',
    );
    restored.dispose();
  });
}
