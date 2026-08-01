import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart'
    show compute, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:url_launcher/url_launcher.dart';

import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/services.dart';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'dxf_layer_processor.dart';
import 'ocr_label_rules.dart';

enum AppLanguage {
  german('de'),
  english('en');

  final String code;

  const AppLanguage(this.code);
}

class AppLanguageController extends ValueNotifier<AppLanguage> {
  static const String _preferenceKey = 'app_language';

  AppLanguageController() : super(AppLanguage.german);

  Future<void> load() async {
    try {
      final prefs = SharedPreferencesAsync();
      final code = await prefs.getString(_preferenceKey);
      value = code == AppLanguage.english.code
          ? AppLanguage.english
          : AppLanguage.german;
    } catch (_) {
      value = AppLanguage.german;
    }
  }

  Future<void> change(AppLanguage language) async {
    if (value != language) value = language;
    try {
      final prefs = SharedPreferencesAsync();
      await prefs.setString(_preferenceKey, language.code);
    } catch (_) {
      // Die Sprache bleibt für die aktuelle Sitzung trotzdem aktiv.
    }
  }
}

final AppLanguageController appLanguageController = AppLanguageController();

bool get isEnglish => appLanguageController.value == AppLanguage.english;

String tr(String german, String english) => isEnglish ? english : german;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await appLanguageController.load();
  runApp(const AToolApp());
}

class AToolApp extends StatelessWidget {
  const AToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppLanguage>(
      valueListenable: appLanguageController,
      builder: (context, language, _) => MaterialApp(
        title: 'ATool',
        debugShowCheckedModeBanner: false,
        locale: Locale(language.code),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        ),
        home: const SplashPage(),
      ),
    );
  }
}

class AppConfig {
  static const String baseUrl = 'https://adler-aufmasse.de/licensing/api';
  static const String catalogUrl =
      'https://adler-aufmasse.de/wp-json/adler/v1/catalog';
  static const String frankeLabelMappingAsset =
      'assets/data/franke_label_mapping.json';
  static const String dwgListUrl =
      'https://adler-aufmasse.de/wp-json/adler/v1/dwg-list';
  static const String logUrl =
      'https://adler-aufmasse.de/wp-json/adler/v1/log-search';
  static const String mediaBaseUrl =
      'https://adler-aufmasse.de/wp-content/Adler/';
  static const String ocrUrl = 'https://adler-aufmasse.de/wp-json/adler/v1/ocr';
  static const String privacyPolicyUrl =
      'https://adler-aufmasse.de/datenschutz/';
}

bool get selfRegistrationAvailable => !kIsWeb && !Platform.isIOS;

class AppStorage {
  static const FlutterSecureStorage storage = FlutterSecureStorage();
  static const Uuid uuid = Uuid();
  static const Duration secureStorageTimeout = Duration(seconds: 3);

  static Future<String?> _read(String key) async {
    try {
      return await storage.read(key: key).timeout(secureStorageTimeout);
    } catch (_) {
      await _delete(key);
      return null;
    }
  }

  static Future<void> _write(String key, String value) async {
    try {
      await storage.write(key: key, value: value).timeout(secureStorageTimeout);
    } catch (_) {
      await _delete(key);
      await storage.write(key: key, value: value).timeout(secureStorageTimeout);
    }
  }

  static Future<void> _delete(String key) async {
    try {
      await storage.delete(key: key).timeout(secureStorageTimeout);
    } catch (_) {}
  }

  static Future<String> getOrCreateDeviceUuid() async {
    final existing = await _read('device_uuid');
    if (existing != null && existing.isNotEmpty) return existing;

    final newUuid = uuid.v4();
    await _write('device_uuid', newUuid);
    return newUuid;
  }

  static Future<String?> getAccessToken() async {
    return _read('access_token');
  }

  static Future<String?> getRefreshToken() async {
    return _read('refresh_token');
  }

  static Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _write('access_token', accessToken);
    await _write('refresh_token', refreshToken);
  }

  static Future<void> updateAccessToken(String accessToken) async {
    await _write('access_token', accessToken);
  }

  static Future<void> clearTokens() async {
    await _delete('access_token');
    await _delete('refresh_token');
    await LicenseCheckPrefs.clear();
  }
}

class LicenseCheckPrefs {
  static const String lastSuccessfulCheckKey = 'license_last_successful_check';
  static const Duration checkInterval = Duration(hours: 24);
  static const Duration offlineGracePeriod = Duration(days: 30);

  static Future<bool> isCheckDue() async {
    final prefs = SharedPreferencesAsync();
    final lastCheck = await prefs.getInt(lastSuccessfulCheckKey);

    if (lastCheck == null || lastCheck <= 0) return true;

    final lastCheckTime = DateTime.fromMillisecondsSinceEpoch(lastCheck);
    return DateTime.now().difference(lastCheckTime) >= checkInterval;
  }

  static Future<void> markSuccessfulCheckNow() async {
    final prefs = SharedPreferencesAsync();
    await prefs.setInt(
      lastSuccessfulCheckKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<bool> isWithinOfflineGracePeriod() async {
    final lastCheck = await getLastSuccessfulCheck();
    if (lastCheck == null || lastCheck <= 0) return false;

    final lastCheckTime = DateTime.fromMillisecondsSinceEpoch(lastCheck);
    final elapsed = DateTime.now().difference(lastCheckTime);
    return !elapsed.isNegative && elapsed <= offlineGracePeriod;
  }

  static Future<int?> getLastSuccessfulCheck() async {
    final prefs = SharedPreferencesAsync();
    return prefs.getInt(lastSuccessfulCheckKey);
  }

  static Future<int> getOfflineDaysRemaining() async {
    final lastCheck = await getLastSuccessfulCheck();
    if (lastCheck == null || lastCheck <= 0) return 0;

    final elapsed = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(lastCheck),
    );
    if (elapsed.isNegative || elapsed >= offlineGracePeriod) return 0;

    final remaining = offlineGracePeriod - elapsed;
    return (remaining.inHours / 24).ceil();
  }

  static Future<void> clear() async {
    final prefs = SharedPreferencesAsync();
    await prefs.remove(lastSuccessfulCheckKey);
  }
}

class DownloadPrefs {
  static const String downloadDirKey = 'download_dir';
  static const String downloadDirLabelKey = 'download_dir_label';

  static Future<String?> getDownloadDir() async {
    final prefs = SharedPreferencesAsync();
    return await prefs.getString(downloadDirKey);
  }

  static Future<void> setDownloadDir(String path) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString(downloadDirKey, path);
  }

  static Future<String?> getDownloadDirLabel() async {
    final prefs = SharedPreferencesAsync();
    return await prefs.getString(downloadDirLabelKey);
  }

  static Future<void> setDownloadDirLabel(String label) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString(downloadDirLabelKey, label);
  }

  static Future<void> clearDownloadDir() async {
    final prefs = SharedPreferencesAsync();
    await prefs.remove(downloadDirKey);
    await prefs.remove(downloadDirLabelKey);
  }
}

class DxfLayerPrefs {
  static const String enabledKey = 'dxf_layer_processing_enabled';
  static const String falzLayerKey = 'dxf_ausschnitt_falz_layer';
  static const String gesaegtLayerKey = 'dxf_ausschnitt_gesaegt_layer';
  static const String auflageLayerKey = 'dxf_ausschnitt_auflage_layer';
  static const String unterbauLayerKey = 'dxf_ausschnitt_unterbau_layer';
  static const String bohrungLayerKey = 'dxf_ausschnitt_bohrung_layer';
  static const String konstruktionLayerKey =
      'dxf_ausschnitt_konstruktion_layer';
  static const String falzColorKey = 'dxf_ausschnitt_falz_color';
  static const String gesaegtColorKey = 'dxf_ausschnitt_gesaegt_color';
  static const String auflageColorKey = 'dxf_ausschnitt_auflage_color';
  static const String unterbauColorKey = 'dxf_ausschnitt_unterbau_color';
  static const String bohrungColorKey = 'dxf_ausschnitt_bohrung_color';
  static const String konstruktionColorKey =
      'dxf_ausschnitt_konstruktion_color';
  static const String defaultFalzLayer = 'AUSSCHNITT_Falz';
  static const String defaultGesaegtLayer = 'AUSSCHNITT_gesaegt';
  static const String defaultAuflageLayer = 'AUSSCHNITT_Auflage';
  static const String defaultUnterbauLayer = 'AUSSCHNITT_Unterbau';
  static const String defaultBohrungLayer = 'AUSSCHNITT_Bohrung';
  static const String defaultKonstruktionLayer = 'Konstruktion';
  static const int defaultLayerColor = 7;

  static Future<DxfLayerSettings> getSettings() async {
    final prefs = SharedPreferencesAsync();
    final enabled = await prefs.getBool(enabledKey);
    final falzLayer = await prefs.getString(falzLayerKey);
    final gesaegtLayer = await prefs.getString(gesaegtLayerKey);
    final auflageLayer = await prefs.getString(auflageLayerKey);
    final unterbauLayer = await prefs.getString(unterbauLayerKey);
    final bohrungLayer = await prefs.getString(bohrungLayerKey);
    final konstruktionLayer = await prefs.getString(konstruktionLayerKey);

    return DxfLayerSettings(
      enabled: enabled ?? false,
      falzLayer: _cleanLayerName(falzLayer, defaultFalzLayer),
      gesaegtLayer: _cleanLayerName(gesaegtLayer, defaultGesaegtLayer),
      auflageLayer: _cleanLayerName(auflageLayer, defaultAuflageLayer),
      unterbauLayer: _cleanLayerName(unterbauLayer, defaultUnterbauLayer),
      bohrungLayer: _cleanLayerName(bohrungLayer, defaultBohrungLayer),
      konstruktionLayer: _cleanLayerName(
        konstruktionLayer,
        defaultKonstruktionLayer,
      ),
      falzColor: await _getColor(prefs, falzColorKey),
      gesaegtColor: await _getColor(prefs, gesaegtColorKey),
      auflageColor: await _getColor(prefs, auflageColorKey),
      unterbauColor: await _getColor(prefs, unterbauColorKey),
      bohrungColor: await _getColor(prefs, bohrungColorKey),
      konstruktionColor: await _getColor(prefs, konstruktionColorKey),
    );
  }

  static Future<void> setSettings(DxfLayerSettings settings) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setBool(enabledKey, settings.enabled);
    await prefs.setString(falzLayerKey, settings.falzLayer.trim());
    await prefs.setString(gesaegtLayerKey, settings.gesaegtLayer.trim());
    await prefs.setString(auflageLayerKey, settings.auflageLayer.trim());
    await prefs.setString(unterbauLayerKey, settings.unterbauLayer.trim());
    await prefs.setString(bohrungLayerKey, settings.bohrungLayer.trim());
    await prefs.setString(
      konstruktionLayerKey,
      settings.konstruktionLayer.trim(),
    );
    await prefs.setInt(falzColorKey, settings.falzColor);
    await prefs.setInt(gesaegtColorKey, settings.gesaegtColor);
    await prefs.setInt(auflageColorKey, settings.auflageColor);
    await prefs.setInt(unterbauColorKey, settings.unterbauColor);
    await prefs.setInt(bohrungColorKey, settings.bohrungColor);
    await prefs.setInt(konstruktionColorKey, settings.konstruktionColor);
  }

  static String _cleanLayerName(String? value, String fallback) {
    final cleanValue = value?.trim() ?? '';
    if (cleanValue.isEmpty) return fallback;
    return cleanValue.replaceAll(RegExp(r'\s+'), '_');
  }

  static Future<int> _getColor(SharedPreferencesAsync prefs, String key) async {
    final color = await prefs.getInt(key);
    return _cleanColor(color);
  }

  static int _cleanColor(int? value) {
    if (value == null) return defaultLayerColor;
    if (value < 1) return 1;
    if (value > 255) return 255;
    return value;
  }
}

class CatalogCachePrefs {
  static const String catalogJsonKey = 'catalog_json_cache';
  static const String catalogCachedAtKey = 'catalog_json_cached_at';
  static const String dwgDisplayCountKey = 'dwg_display_count_cache';

  static Future<String?> getCatalogJson() async {
    final prefs = SharedPreferencesAsync();
    return await prefs.getString(catalogJsonKey);
  }

  static Future<void> setCatalogJson(String json) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString(catalogJsonKey, json);
    await prefs.setInt(
      catalogCachedAtKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  static Future<DateTime?> getCatalogCachedAt() async {
    final prefs = SharedPreferencesAsync();
    final value = await prefs.getInt(catalogCachedAtKey);
    return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  static Future<int?> getDwgDisplayCount() async {
    final prefs = SharedPreferencesAsync();
    return await prefs.getInt(dwgDisplayCountKey);
  }

  static Future<void> setDwgDisplayCount(int count) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setInt(dwgDisplayCountKey, count);
  }
}

class CatalogItem {
  final String id;
  final String manufacturer;
  final String type;
  final String basename;
  final String? dwgPath;
  final String? dxfPath;
  final String? jpgPath;
  final bool dwgExists;
  final bool dxfExists;
  final bool jpgExists;

  const CatalogItem({
    required this.id,
    required this.manufacturer,
    required this.type,
    required this.basename,
    required this.dwgPath,
    required this.dxfPath,
    required this.jpgPath,
    required this.dwgExists,
    required this.dxfExists,
    required this.jpgExists,
  });

  factory CatalogItem.fromJson(Map<String, dynamic> json) {
    return CatalogItem(
      id: (json['id'] ?? '').toString(),
      manufacturer: (json['manufacturer'] ?? '').toString(),
      type: (json['type'] ?? '').toString(),
      basename: (json['basename'] ?? '').toString(),
      dwgPath: json['dwg_path']?.toString(),
      dxfPath: json['dxf_path']?.toString(),
      jpgPath: json['jpg_path']?.toString(),
      dwgExists: json['dwg_exists'] == true,
      dxfExists: json['dxf_exists'] == true,
      jpgExists: json['jpg_exists'] == true,
    );
  }

  String? get jpgUrl =>
      jpgPath != null ? '${AppConfig.mediaBaseUrl}$jpgPath' : null;

  String? get dxfUrl =>
      dxfPath != null ? '${AppConfig.mediaBaseUrl}$dxfPath' : null;

  String? get dwgUrl =>
      dwgPath != null ? '${AppConfig.mediaBaseUrl}$dwgPath' : null;
}

class FrankeLabelMapping {
  final String catalog;
  final String materialText;
  final String label;

  const FrankeLabelMapping({
    required this.catalog,
    required this.materialText,
    required this.label,
  });

  factory FrankeLabelMapping.fromJson(Map<String, dynamic> json) {
    return FrankeLabelMapping(
      catalog: (json['catalog'] ?? '').toString(),
      materialText: (json['material_text'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
    );
  }
}

Map<String, Object> _saveReducedOfflineImageInBackground(
  Map<String, Object> input,
) {
  final bytes = input['bytes']! as Uint8List;
  final outputPath = input['outputPath']! as String;

  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return {'success': false, 'size': 0};

    // Offline-Vorschauen werden auf 60 % der ursprünglichen Abmessungen
    // reduziert. Das Originalbild bleibt ausschließlich auf dem Server.
    final width = (decoded.width * 0.6).round();
    final height = (decoded.height * 0.6).round();
    final reduced = img.copyResize(
      decoded,
      width: width < 1 ? 1 : width,
      height: height < 1 ? 1 : height,
      interpolation: img.Interpolation.linear,
    );
    final encoded = img.encodeJpg(reduced, quality: 72);
    File(outputPath).writeAsBytesSync(encoded, flush: true);

    return {'success': true, 'size': encoded.length};
  } catch (_) {
    try {
      final file = File(outputPath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    return {'success': false, 'size': 0};
  }
}

class OfflineImageStatus {
  final int imageCount;
  final int totalBytes;
  final DateTime? lastUpdated;

  const OfflineImageStatus({
    required this.imageCount,
    required this.totalBytes,
    required this.lastUpdated,
  });
}

class OfflineImageSyncResult {
  final int total;
  final int available;
  final int failed;
  final bool cancelled;

  const OfflineImageSyncResult({
    required this.total,
    required this.available,
    required this.failed,
    required this.cancelled,
  });
}

typedef OfflineImageProgressCallback =
    void Function(int processed, int total, int available, int failed);

class OfflineImageSyncCancellation {
  bool isCancelled = false;
  http.Client? _client;

  void _attach(http.Client client) => _client = client;

  void cancel() {
    isCancelled = true;
    _client?.close();
  }
}

class OfflineImageStore {
  static const String _directoryName = 'offline_article_images';
  static const String _lastUpdatedKey = 'offline_images_last_updated';

  static Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}$_directoryName',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  static String _fileNameForUrl(String url) {
    int hash(Iterable<int> units) {
      var value = 0x811C9DC5;
      for (final unit in units) {
        value ^= unit;
        value = (value * 0x01000193) & 0xFFFFFFFF;
      }
      return value;
    }

    final first = hash(url.codeUnits).toRadixString(16).padLeft(8, '0');
    final second = hash(
      url.codeUnits.reversed,
    ).toRadixString(16).padLeft(8, '0');
    return '$first$second.jpg';
  }

  static Future<String> _pathForUrl(String url) async {
    final directory = await _directory();
    return '${directory.path}${Platform.pathSeparator}${_fileNameForUrl(url)}';
  }

  static Future<String?> existingPathForUrl(String url) async {
    if (url.trim().isEmpty) return null;
    try {
      final path = await _pathForUrl(url);
      final file = File(path);
      if (await file.exists() && await file.length() > 0) return path;
    } catch (_) {}
    return null;
  }

  static Future<OfflineImageStatus> getStatus() async {
    var count = 0;
    var bytes = 0;

    try {
      final directory = await _directory();
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.toLowerCase().endsWith('.jpg')) {
          continue;
        }
        count++;
        bytes += await entity.length();
      }
    } catch (_) {}

    final prefs = SharedPreferencesAsync();
    final lastUpdatedValue = await prefs.getInt(_lastUpdatedKey);
    return OfflineImageStatus(
      imageCount: count,
      totalBytes: bytes,
      lastUpdated: lastUpdatedValue == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastUpdatedValue),
    );
  }

  static Future<OfflineImageSyncResult> synchronize(
    List<CatalogItem> catalog, {
    required OfflineImageProgressCallback onProgress,
    required OfflineImageSyncCancellation cancellation,
  }) async {
    final urls = catalog
        .where((item) => item.jpgExists)
        .map((item) => item.jpgUrl?.trim() ?? '')
        .where((url) => url.isNotEmpty)
        .toSet()
        .toList();
    final total = urls.length;
    final directory = await _directory();
    final expectedFiles = urls.map(_fileNameForUrl).toSet();
    var processed = 0;
    var available = 0;
    var failed = 0;
    var nextIndex = 0;
    final client = http.Client();
    cancellation._attach(client);

    Future<void> worker() async {
      while (!cancellation.isCancelled) {
        if (nextIndex >= urls.length) return;
        final url = urls[nextIndex++];
        final path =
            '${directory.path}${Platform.pathSeparator}${_fileNameForUrl(url)}';
        final file = File(path);

        try {
          if (await file.exists() && await file.length() > 0) {
            available++;
          } else {
            final response = await client
                .get(Uri.parse(url))
                .timeout(const Duration(seconds: 20));
            if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
              failed++;
            } else {
              final result = await compute(
                _saveReducedOfflineImageInBackground,
                {'bytes': response.bodyBytes, 'outputPath': path},
              );
              if (result['success'] == true) {
                available++;
              } else {
                failed++;
              }
            }
          }
        } catch (_) {
          if (!cancellation.isCancelled) failed++;
        }

        processed++;
        onProgress(processed, total, available, failed);
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));

    client.close();
    cancellation._client = null;

    final cancelled = cancellation.isCancelled;
    if (!cancelled) {
      try {
        await for (final entity in directory.list()) {
          if (entity is File) {
            final name = entity.uri.pathSegments.last;
            if (name.endsWith('.jpg') && !expectedFiles.contains(name)) {
              await entity.delete();
            }
          }
        }
      } catch (_) {}

      final prefs = SharedPreferencesAsync();
      await prefs.setInt(
        _lastUpdatedKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    }

    return OfflineImageSyncResult(
      total: total,
      available: available,
      failed: failed,
      cancelled: cancelled,
    );
  }

  static Future<void> clear() async {
    try {
      final directory = await _directory();
      await for (final entity in directory.list()) {
        if (entity is File) await entity.delete();
      }
    } catch (_) {}

    final prefs = SharedPreferencesAsync();
    await prefs.remove(_lastUpdatedKey);
  }
}

String _formatStorageSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

List<CatalogItem> _parseCatalogItemsInBackground(String responseBody) {
  final data = jsonDecode(responseBody) as Map<String, dynamic>;
  final itemsRaw = (data['items'] as List<dynamic>? ?? []);

  return itemsRaw
      .whereType<Map>()
      .map((e) => CatalogItem.fromJson(Map<String, dynamic>.from(e)))
      .toList();
}

List<FrankeLabelMapping> _parseFrankeLabelMappingsInBackground(
  String responseBody,
) {
  final data = jsonDecode(responseBody);
  final itemsRaw = data is List ? data : const [];

  return itemsRaw
      .whereType<Map>()
      .map((e) => FrankeLabelMapping.fromJson(Map<String, dynamic>.from(e)))
      .where((e) => e.catalog.trim().isNotEmpty && e.label.trim().isNotEmpty)
      .toList();
}

int? _parseDwgDisplayCountInBackground(String responseBody) {
  final data = jsonDecode(responseBody);

  if (data is Map<String, dynamic>) {
    final items = data['items'];
    if (items is List) return items.length;
    return data.keys.length;
  }

  if (data is List) return data.length;

  return null;
}

Map<String, Object> _prepareOcrInputImageInBackground(
  Map<String, Object> input,
) {
  final originalPath = input['path']! as String;
  final maxOcrImageSide = input['maxSide']! as int;

  try {
    final bytes = File(originalPath).readAsBytesSync();
    final decoded = img.decodeImage(bytes);

    if (decoded == null) {
      return {'path': originalPath, 'isTemporary': false};
    }

    final longestSide = decoded.width > decoded.height
        ? decoded.width
        : decoded.height;

    if (longestSide <= maxOcrImageSide) {
      return {'path': originalPath, 'isTemporary': false};
    }

    final scale = maxOcrImageSide / longestSide;
    final resized = img.copyResize(
      decoded,
      width: (decoded.width * scale).round(),
      height: (decoded.height * scale).round(),
      interpolation: img.Interpolation.linear,
    );
    final resizedPath =
        '${Directory.systemTemp.path}/atool_ocr_resized_${DateTime.now().microsecondsSinceEpoch}.jpg';

    File(resizedPath).writeAsBytesSync(img.encodeJpg(resized, quality: 88));

    return {'path': resizedPath, 'isTemporary': true};
  } catch (e) {
    return {'path': originalPath, 'isTemporary': false, 'error': e.toString()};
  }
}

List<Map<String, Object>> _buildFallbackOcrImageVariantsInBackground(
  String originalPath,
) {
  final variants = <Map<String, Object>>[];

  try {
    final bytes = File(originalPath).readAsBytesSync();
    final decoded = img.decodeImage(bytes);

    if (decoded == null) return variants;

    for (final rotation in [180, 90, 270]) {
      final rotated = img.copyRotate(decoded, angle: rotation);
      final rotatedPath =
          '${Directory.systemTemp.path}/atool_ocr_rotated_${rotation}_${DateTime.now().microsecondsSinceEpoch}.jpg';

      File(rotatedPath).writeAsBytesSync(img.encodeJpg(rotated, quality: 88));
      variants.add({'path': rotatedPath, 'rotation': rotation});
    }
  } catch (e) {
    debugPrint('OCR ROTATION FAILED: $e');
  }

  return variants;
}

class CatalogSearchEntry {
  final CatalogItem item;
  final String searchText;
  final String compactText;
  final String manualSearchText;
  final String manualCompactText;
  final List<String> fieldTexts;
  final List<String> fieldCompacts;
  final Set<String> tokens;

  const CatalogSearchEntry({
    required this.item,
    required this.searchText,
    required this.compactText,
    required this.manualSearchText,
    required this.manualCompactText,
    required this.fieldTexts,
    required this.fieldCompacts,
    required this.tokens,
  });
}

class _CatalogIndexBuildResult {
  final List<CatalogSearchEntry> searchEntries;
  final Map<String, List<CatalogItem>> ocrLookupIndex;

  const _CatalogIndexBuildResult({
    required this.searchEntries,
    required this.ocrLookupIndex,
  });
}

class _CatalogIndexBuildInput {
  final List<CatalogItem> catalog;
  final List<FrankeLabelMapping> frankeLabelMappings;

  const _CatalogIndexBuildInput({
    required this.catalog,
    required this.frankeLabelMappings,
  });
}

_CatalogIndexBuildResult _buildCatalogSearchIndexInBackground(
  _CatalogIndexBuildInput input,
) {
  const minSearchLen = 4;
  final catalog = input.catalog;
  final frankeLabelsByCatalogKey = _buildFrankeLabelsByCatalogKey(
    input.frankeLabelMappings,
  );
  final searchEntries = <CatalogSearchEntry>[];
  final ocrLookupIndex = <String, List<CatalogItem>>{};

  void addOcrLookupKey(CatalogItem item, String key) {
    final trimmed = key.trim();
    if (trimmed.length < minSearchLen) return;
    if (RegExp(r'^\d{12,}$').hasMatch(trimmed)) return;

    final bucket = ocrLookupIndex.putIfAbsent(trimmed, () => []);
    final itemKey = '${item.id}|${item.basename}';
    if (!bucket.any(
      (existing) => '${existing.id}|${existing.basename}' == itemKey,
    )) {
      bucket.add(item);
    }
  }

  for (final item in catalog) {
    final frankeLabelFields = _frankeLabelFieldsForItem(
      item,
      frankeLabelsByCatalogKey,
    );
    final rawFields = <String>[
      item.basename,
      item.id,
      item.dwgPath ?? '',
      item.dxfPath ?? '',
      item.jpgPath ?? '',
      ...frankeLabelFields,
    ].where((e) => e.trim().isNotEmpty).toList();

    final manualRawFields = <String>[
      item.manufacturer,
      item.type,
      ...rawFields,
    ].where((e) => e.trim().isNotEmpty).toList();

    final fieldTexts = rawFields
        .map(_normalizeCatalogSearchText)
        .where((e) => e.trim().isNotEmpty)
        .toList();

    final fieldCompacts = fieldTexts
        .map((e) => e.replaceAll(RegExp(r'[^a-z0-9]'), ''))
        .where((e) => e.length >= minSearchLen)
        .toList();

    final searchText = fieldTexts.join(' ');
    final compactText = searchText.replaceAll(RegExp(r'[^a-z0-9]'), '');

    final manualFieldTexts = manualRawFields
        .map(_normalizeCatalogSearchText)
        .where((e) => e.trim().isNotEmpty)
        .toList();
    final manualSearchText = manualFieldTexts.join(' ');
    final manualCompactText = manualSearchText.replaceAll(
      RegExp(r'[^a-z0-9]'),
      '',
    );

    final tokens = searchText
        .split(RegExp(r'[\s\-/._]+'))
        .map((e) => e.trim())
        .where((e) => e.length >= 2)
        .toSet();

    for (final value in {
      ...manualFieldTexts,
      ...fieldCompacts,
      manualCompactText,
      compactText,
    }) {
      addOcrLookupKey(item, value);
    }

    searchEntries.add(
      CatalogSearchEntry(
        item: item,
        searchText: searchText,
        compactText: compactText,
        manualSearchText: manualSearchText,
        manualCompactText: manualCompactText,
        fieldTexts: fieldTexts,
        fieldCompacts: fieldCompacts,
        tokens: tokens,
      ),
    );
  }

  return _CatalogIndexBuildResult(
    searchEntries: searchEntries,
    ocrLookupIndex: ocrLookupIndex,
  );
}

Map<String, List<String>> _buildFrankeLabelsByCatalogKey(
  List<FrankeLabelMapping> mappings,
) {
  final labelsByCatalogKey = <String, List<String>>{};

  void addLabel(String catalogValue, String labelValue) {
    final label = labelValue.trim();
    if (label.isEmpty) return;

    for (final key in _buildFrankeArticleKeys(catalogValue)) {
      final labels = labelsByCatalogKey.putIfAbsent(key, () => []);
      if (!labels.contains(label)) labels.add(label);
    }
  }

  for (final mapping in mappings) {
    addLabel(mapping.catalog, mapping.label);
  }

  return labelsByCatalogKey;
}

List<String> _frankeLabelFieldsForItem(
  CatalogItem item,
  Map<String, List<String>> labelsByCatalogKey,
) {
  final labels = <String>[];

  for (final value in [
    item.id,
    item.basename,
    item.dwgPath ?? '',
    item.dxfPath ?? '',
    item.jpgPath ?? '',
  ]) {
    for (final key in _buildFrankeArticleKeys(value)) {
      final foundLabels = labelsByCatalogKey[key];
      if (foundLabels == null) continue;

      for (final label in foundLabels) {
        if (!labels.contains(label)) labels.add(label);
      }
    }
  }

  return labels;
}

Set<String> _buildFrankeArticleKeys(String input) {
  final normalized = _normalizeCatalogSearchText(input);
  final compact = normalized.replaceAll(RegExp(r'[^a-z0-9]'), '');
  final keys = <String>{};

  if (normalized.length >= 4) keys.add(normalized);
  if (compact.length >= 4) keys.add(compact);

  for (final match in RegExp(
    r'\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+',
  ).allMatches(normalized)) {
    final value = match.group(0);
    if (value == null) continue;

    final article = _normalizeCatalogSearchText(value);
    final articleCompact = article.replaceAll(RegExp(r'[^a-z0-9]'), '');

    if (article.length >= 4) keys.add(article);
    if (articleCompact.length >= 4) keys.add(articleCompact);
  }

  return keys;
}

String _normalizeCatalogSearchText(String input) {
  var s = input.toLowerCase().trim();

  const replacements = {'ä': 'a', 'ö': 'o', 'ü': 'u', 'ß': 'ss'};

  replacements.forEach((key, value) {
    s = s.replaceAll(key, value);
  });

  s = s.replaceAll(RegExp(r'[^a-z0-9/_. -]'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  final parts = s
      .split(' ')
      .map((part) {
        if (RegExp(r'^0+\d+$').hasMatch(part)) {
          return part.replaceFirst(RegExp(r'^0+'), '');
        }

        return part;
      })
      .where((e) => e.isNotEmpty)
      .toList();

  return parts.join(' ');
}

class DeviceMeta {
  final String platform;
  final String deviceName;
  final String osVersion;
  final String appVersion;

  const DeviceMeta({
    required this.platform,
    required this.deviceName,
    required this.osVersion,
    required this.appVersion,
  });
}

class DeviceMetaService {
  static Future<DeviceMeta> load() async {
    final deviceInfo = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();

    String platformName = 'unknown';
    String deviceName = tr('Unbekanntes Gerät', 'Unknown device');
    String osVersion = 'Unbekannt';
    final appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';

    if (kIsWeb) {
      final web = await deviceInfo.webBrowserInfo;
      platformName = 'web';
      deviceName = web.browserName.name;
      osVersion = web.userAgent ?? 'Web';
    } else if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      platformName = 'android';
      deviceName = '${android.manufacturer} ${android.model}'.trim();
      osVersion = 'Android ${android.version.release}';
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      platformName = 'ios';
      deviceName = '${ios.name} ${ios.model}'.trim();
      osVersion = '${ios.systemName} ${ios.systemVersion}';
    } else {
      platformName = 'desktop';
      deviceName = 'Desktop';
      osVersion = 'Unbekannt';
    }

    return DeviceMeta(
      platform: platformName,
      deviceName: deviceName,
      osVersion: osVersion,
      appVersion: appVersion,
    );
  }
}

class ApiService {
  static const Duration requestTimeout = Duration(seconds: 12);

  static Future<http.Response> _get(Uri uri, {Map<String, String>? headers}) {
    return http.get(uri, headers: headers).timeout(requestTimeout);
  }

  static Future<http.Response> _post(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) {
    return http.post(uri, headers: headers, body: body).timeout(requestTimeout);
  }

  static Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final deviceUuid = await AppStorage.getOrCreateDeviceUuid();
    final meta = await DeviceMetaService.load();

    final uri = Uri.parse('${AppConfig.baseUrl}/login.php');

    final response = await _post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
        'device_uuid': deviceUuid,
        'platform': meta.platform,
        'device_name': meta.deviceName,
        'os_version': meta.osVersion,
        'app_version': meta.appVersion,
      }),
    );

    return Map<String, dynamic>.from(jsonDecode(response.body));
  }

  static Future<Map<String, dynamic>> registerTrial({
    required String companyName,
    required String name,
    required String email,
    required String password,
    String phone = '',
  }) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/register-trial.php');

    final response = await _post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'company_name': companyName.trim(),
        'name': name.trim(),
        'email': email.trim(),
        'password': password,
        'phone': phone.trim(),
      }),
    );

    return Map<String, dynamic>.from(jsonDecode(response.body));
  }

  static Future<Map<String, dynamic>> requestPasswordReset({
    required String email,
  }) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/forgot-password.php');

    final response = await _post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email.trim()}),
    );

    return Map<String, dynamic>.from(jsonDecode(response.body));
  }

  static Future<Map<String, dynamic>> refreshAccessToken() async {
    final refreshToken = await AppStorage.getRefreshToken();

    if (refreshToken == null || refreshToken.isEmpty) {
      return {'success': false, 'message': 'Kein Refresh Token vorhanden'};
    }

    final uri = Uri.parse('${AppConfig.baseUrl}/refresh-token.php');

    final response = await _post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': refreshToken}),
    );

    final data = Map<String, dynamic>.from(jsonDecode(response.body));

    if (data['success'] == true && data['session'] != null) {
      final newAccessToken = data['session']['access_token'] ?? '';
      if (newAccessToken is String && newAccessToken.isNotEmpty) {
        await AppStorage.updateAccessToken(newAccessToken);
      }
    }

    return data;
  }

  static Future<Map<String, dynamic>> getLicenseStatus() async {
    final accessToken = await AppStorage.getAccessToken();

    if (accessToken == null || accessToken.isEmpty) {
      return {'success': false, 'message': 'Kein Access Token gefunden'};
    }

    final uri = Uri.parse('${AppConfig.baseUrl}/license-status.php');

    final response = await _get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    final data = Map<String, dynamic>.from(jsonDecode(response.body));

    if (data['success'] == true) return data;

    final message = (data['message'] ?? '').toString().toLowerCase();
    final tokenProblem =
        message.contains('abgelaufen') ||
        message.contains('ungültiger access token') ||
        message.contains('kein access token');

    if (tokenProblem) {
      final refreshData = await refreshAccessToken();

      if (refreshData['success'] == true) {
        final newAccessToken = await AppStorage.getAccessToken();

        if (newAccessToken == null || newAccessToken.isEmpty) {
          return {
            'success': false,
            'message':
                'Refresh erfolgreich, aber kein neuer Access Token gespeichert',
          };
        }

        final retryResponse = await _get(
          uri,
          headers: {'Authorization': 'Bearer $newAccessToken'},
        );

        return Map<String, dynamic>.from(jsonDecode(retryResponse.body));
      }

      return {
        'success': false,
        'message': 'Token-Erneuerung fehlgeschlagen',
        'refresh_response': refreshData,
      };
    }

    return data;
  }

  static Future<void> logout() async {
    try {
      final accessToken = await AppStorage.getAccessToken();

      if (accessToken != null && accessToken.isNotEmpty) {
        final uri = Uri.parse('${AppConfig.baseUrl}/logout.php');

        await _post(uri, headers: {'Authorization': 'Bearer $accessToken'});
      }
    } catch (_) {}

    await AppStorage.clearTokens();
  }
}

String mapLoginErrorMessage(Map<String, dynamic> data) {
  final message = (data['message'] ?? '').toString();

  if (message.contains('Passwort ist falsch')) {
    return tr('Das Passwort ist falsch.', 'The password is incorrect.');
  }
  if (message.contains('Benutzer nicht gefunden')) {
    return tr('Dieser Benutzer wurde nicht gefunden.', 'User not found.');
  }
  if (message.contains('Benutzer ist gesperrt')) {
    return tr('Dieser Benutzer ist gesperrt.', 'This user is blocked.');
  }
  if (message.contains('Firma ist nicht aktiv')) {
    return tr(
      'Die Firma ist aktuell nicht aktiv.',
      'The company is currently inactive.',
    );
  }
  if (message.contains('Lizenz ist abgelaufen')) {
    return tr('Die Lizenz ist abgelaufen.', 'The license has expired.');
  }
  if (message.contains('Maximale Anzahl aktiver Geräte erreicht')) {
    return tr(
      'Die maximale Anzahl aktiver Geräte wurde erreicht.',
      'The maximum number of active devices has been reached.',
    );
  }
  if (message.contains('Gerät ist nicht aktiv')) {
    return tr('Dieses Gerät ist nicht aktiv.', 'This device is inactive.');
  }

  return message.isNotEmpty
      ? message
      : tr('Unbekannter Login-Fehler.', 'Unknown login error.');
}

Color statusColor(String status) {
  switch (status.toLowerCase()) {
    case 'active':
      return Colors.green;
    case 'blocked':
      return Colors.red;
    case 'expired':
      return Colors.orange;
    case 'test':
      return Colors.blue;
    case 'removed':
      return Colors.grey;
    default:
      return Colors.black54;
  }
}

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    _checkLogin();
  }

  Future<void> _checkLogin() async {
    try {
      await AppStorage.getOrCreateDeviceUuid();

      final accessToken = await AppStorage.getAccessToken();
      final refreshToken = await AppStorage.getRefreshToken();

      if (!mounted) return;

      if ((accessToken != null && accessToken.isNotEmpty) ||
          (refreshToken != null && refreshToken.isNotEmpty)) {
        if (!await LicenseCheckPrefs.isCheckDue()) {
          if (!mounted) return;

          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const MainSearchPage()),
          );
          return;
        }

        final data = await ApiService.getLicenseStatus();

        if (!mounted) return;

        if (data['success'] != true) {
          await AppStorage.clearTokens();
          if (!mounted) return;

          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => LoginPage(
                initialErrorMessage: tr(
                  'Sitzung oder Lizenz ist nicht mehr gültig. Bitte erneut anmelden.',
                  'The session or license is no longer valid. Please log in again.',
                ),
              ),
            ),
          );
          return;
        }

        await LicenseCheckPrefs.markSuccessfulCheckNow();
        if (!mounted) return;

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainSearchPage()),
        );
      } else {
        Navigator.of(
          context,
        ).pushReplacement(MaterialPageRoute(builder: (_) => const LoginPage()));
      }
    } catch (_) {
      if (await LicenseCheckPrefs.isWithinOfflineGracePeriod()) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainSearchPage()),
        );
        return;
      }

      await AppStorage.clearTokens();

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => LoginPage(
            initialErrorMessage: tr(
              'Lizenz konnte nicht geprüft werden. Bitte erneut anmelden.',
              'The license could not be verified. Please log in again.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class LoginPage extends StatefulWidget {
  final String initialErrorMessage;

  const LoginPage({super.key, this.initialErrorMessage = ''});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _isPasswordVisible = false;
  String _errorMessage = '';
  String _successMessage = '';
  String _deviceUuid = '';

  @override
  void initState() {
    super.initState();
    _errorMessage = widget.initialErrorMessage;
    _loadDeviceUuid();
  }

  Future<void> _loadDeviceUuid() async {
    final uuid = await AppStorage.getOrCreateDeviceUuid();
    if (!mounted) return;

    setState(() {
      _deviceUuid = uuid;
    });
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();

    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _successMessage = '';
    });

    try {
      final data = await ApiService.login(
        email: _emailController.text,
        password: _passwordController.text,
      );

      if (data['success'] == true && data['session'] != null) {
        final accessToken = data['session']['access_token'] ?? '';
        final refreshToken = data['session']['refresh_token'] ?? '';

        await AppStorage.saveTokens(
          accessToken: accessToken,
          refreshToken: refreshToken,
        );
        await LicenseCheckPrefs.markSuccessfulCheckNow();

        if (!mounted) return;

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainSearchPage()),
        );
      } else {
        if (!mounted) return;

        setState(() {
          _errorMessage = mapLoginErrorMessage(data);
        });
      }
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _errorMessage = tr(
          'Verbindung fehlgeschlagen. Bitte Internet und Server prüfen.',
          'Connection failed. Please check your internet connection and the server.',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 48,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 430),
                    child: Card(
                      elevation: 6,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Image.asset(
                              'assets/logo/login_logo.png',
                              height: 90,
                              fit: BoxFit.contain,
                            ),
                            const SizedBox(height: 12),
                            const SizedBox(height: 6),
                            Text(
                              tr(
                                'Login für lizenzierte Firmenkunden',
                                'Login for licensed business customers',
                              ),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.black54),
                            ),
                            const SizedBox(height: 24),
                            TextField(
                              controller: _emailController,
                              decoration: InputDecoration(
                                labelText: 'E-Mail',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                prefixIcon: const Icon(Icons.email_outlined),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _passwordController,
                              obscureText: !_isPasswordVisible,
                              onSubmitted: (_) => _isLoading ? null : _login(),
                              decoration: InputDecoration(
                                labelText: tr('Passwort', 'Password'),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  tooltip: _isPasswordVisible
                                      ? tr(
                                          'Passwort ausblenden',
                                          'Hide password',
                                        )
                                      : tr(
                                          'Passwort anzeigen',
                                          'Show password',
                                        ),
                                  onPressed: () {
                                    setState(() {
                                      _isPasswordVisible = !_isPasswordVisible;
                                    });
                                  },
                                  icon: Icon(
                                    _isPasswordVisible
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: _isLoading
                                    ? null
                                    : () async {
                                        final email =
                                            await Navigator.of(
                                              context,
                                            ).push<String>(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    PasswordResetPage(
                                                      initialEmail:
                                                          _emailController.text,
                                                    ),
                                              ),
                                            );

                                        if (!mounted || email == null) return;

                                        _emailController.text = email;
                                        setState(() {
                                          _errorMessage = '';
                                          _successMessage = tr(
                                            'Wenn ein Konto zu dieser E-Mail-Adresse existiert, wurde ein Link zum Zurücksetzen des Passworts versendet.',
                                            'If an account exists for this email address, a password reset link has been sent.',
                                          );
                                        });
                                      },
                                icon: const Icon(Icons.lock_reset, size: 20),
                                label: Text(
                                  tr(
                                    'Passwort vergessen / zurücksetzen',
                                    'Forgot/reset password',
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: SelectableText(
                                '${tr('Geräte-ID', 'Device ID')}: ${_deviceUuid.isEmpty ? tr('wird geladen...', 'loading...') : _deviceUuid}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.black54,
                                ),
                              ),
                            ),
                            if (_successMessage.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.green.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.green.withValues(alpha: 0.25),
                                  ),
                                ),
                                child: Text(
                                  _successMessage,
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                            if (_errorMessage.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.red.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Colors.red.withValues(alpha: 0.25),
                                  ),
                                ),
                                child: Text(
                                  _errorMessage,
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: ElevatedButton.icon(
                                onPressed: _isLoading ? null : _login,
                                icon: _isLoading
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.login),
                                label: Text(
                                  _isLoading
                                      ? tr(
                                          'Anmeldung läuft...',
                                          'Logging in...',
                                        )
                                      : tr('Einloggen', 'Log in'),
                                ),
                                style: ElevatedButton.styleFrom(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),

                            if (!selfRegistrationAvailable)
                              Text(
                                tr(
                                  'Zugang nur für bereits freigeschaltete Firmenkunden.\nBitte verwenden Sie die Zugangsdaten, die Ihnen von Ihrem Unternehmen bereitgestellt wurden.',
                                  'Access is limited to approved business customers.\nPlease use the login details provided by your company.',
                                ),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.black54,
                                  height: 1.35,
                                ),
                              )
                            else
                              TextButton(
                                onPressed: _isLoading
                                    ? null
                                    : () async {
                                        final result =
                                            await Navigator.of(
                                              context,
                                            ).push<String>(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    const RegisterTrialPage(),
                                              ),
                                            );

                                        if (result != null &&
                                            result.isNotEmpty) {
                                          _emailController.text = result;
                                          setState(() {
                                            _errorMessage = '';
                                            _successMessage = tr(
                                              'Registrierung erfolgreich. Bitte bestätigen Sie jetzt Ihre E-Mail-Adresse. Danach können Sie sich einloggen.',
                                              'Registration successful. Please confirm your email address. You can then log in.',
                                            );
                                          });
                                        }
                                      },
                                child: Text(
                                  tr(
                                    '10 Tage testen / Registrieren',
                                    'Try for 10 days / Register',
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class PasswordResetPage extends StatefulWidget {
  final String initialEmail;

  const PasswordResetPage({super.key, this.initialEmail = ''});

  @override
  State<PasswordResetPage> createState() => _PasswordResetPageState();
}

class _PasswordResetPageState extends State<PasswordResetPage> {
  late final TextEditingController _emailController;
  bool _isLoading = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.initialEmail.trim());
  }

  Future<void> _requestReset() async {
    FocusScope.of(context).unfocus();

    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _errorMessage = tr(
          'Bitte geben Sie eine gültige E-Mail-Adresse ein.',
          'Please enter a valid email address.',
        );
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final data = await ApiService.requestPasswordReset(email: email);

      if (!mounted) return;

      if (data['success'] == true) {
        Navigator.of(context).pop(email);
      } else {
        setState(() {
          _errorMessage =
              (data['message'] ??
                      tr(
                        'Das Zurücksetzen ist fehlgeschlagen.',
                        'The reset request failed.',
                      ))
                  .toString();
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage = tr(
          'Zurücksetzen fehlgeschlagen. Bitte Internet und Server prüfen.',
          'Reset failed. Please check your internet connection and the server.',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Passwort zurücksetzen', 'Reset password')),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock_reset, size: 52),
                      const SizedBox(height: 16),
                      Text(
                        tr('Passwort vergessen?', 'Forgot your password?'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        tr(
                          'Geben Sie Ihre registrierte E-Mail-Adresse ein. Sie erhalten anschließend einen Link, mit dem Sie ein neues Passwort festlegen können.',
                          'Enter your registered email address. You will receive a link that lets you set a new password.',
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54, height: 1.4),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _isLoading ? null : _requestReset(),
                        decoration: InputDecoration(
                          labelText: 'E-Mail',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          prefixIcon: const Icon(Icons.email_outlined),
                        ),
                      ),
                      if (_errorMessage.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.red.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Text(
                            _errorMessage,
                            style: const TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _requestReset,
                          icon: _isLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_outlined),
                          label: Text(
                            _isLoading
                                ? tr(
                                    'E-Mail wird angefordert...',
                                    'Requesting email...',
                                  )
                                : tr(
                                    'Link zum Zurücksetzen senden',
                                    'Send reset link',
                                  ),
                          ),
                          style: ElevatedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RegisterTrialPage extends StatefulWidget {
  const RegisterTrialPage({super.key});

  @override
  State<RegisterTrialPage> createState() => _RegisterTrialPageState();
}

class _RegisterTrialPageState extends State<RegisterTrialPage> {
  final _companyController = TextEditingController();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneController = TextEditingController();

  bool _isLoading = false;
  bool _isPasswordVisible = false;
  String _message = '';

  Future<void> _register() async {
    FocusScope.of(context).unfocus();

    setState(() {
      _isLoading = true;
      _message = '';
    });

    try {
      final data = await ApiService.registerTrial(
        companyName: _companyController.text,
        name: _nameController.text,
        email: _emailController.text,
        password: _passwordController.text,
        phone: _phoneController.text,
      );

      if (data['success'] == true) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'Registrierung erfolgreich. Bitte bestätigen Sie jetzt Ihre E-Mail-Adresse.',
                'Registration successful. Please confirm your email address.',
              ),
            ),
          ),
        );

        Navigator.of(context).pop(_emailController.text.trim());
      } else {
        setState(() {
          _message =
              (data['message'] ??
                      tr(
                        'Registrierung fehlgeschlagen.',
                        'Registration failed.',
                      ))
                  .toString();
        });
      }
    } catch (_) {
      setState(() {
        _message = tr(
          'Registrierung fehlgeschlagen. Bitte Serververbindung prüfen.',
          'Registration failed. Please check the server connection.',
        );
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _companyController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('10 Tage testen', '10-day trial'))),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              elevation: 4,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(
                      tr('Testzugang registrieren', 'Register a trial account'),
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr(
                        'Erstelle einen Firmen-Testzugang für 10 Tage.',
                        'Create a 10-day company trial account.',
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _companyController,
                      decoration: InputDecoration(
                        labelText: tr('Firmenname', 'Company name'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        prefixIcon: const Icon(Icons.business_outlined),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: tr('Ansprechpartner', 'Contact person'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        prefixIcon: const Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        labelText: 'E-Mail',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        prefixIcon: const Icon(Icons.email_outlined),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _passwordController,
                      obscureText: !_isPasswordVisible,
                      decoration: InputDecoration(
                        labelText: tr('Passwort', 'Password'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _isPasswordVisible
                              ? tr('Passwort ausblenden', 'Hide password')
                              : tr('Passwort anzeigen', 'Show password'),
                          onPressed: () {
                            setState(() {
                              _isPasswordVisible = !_isPasswordVisible;
                            });
                          },
                          icon: Icon(
                            _isPasswordVisible
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _phoneController,
                      decoration: InputDecoration(
                        labelText: tr('Telefon (optional)', 'Phone (optional)'),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        prefixIcon: const Icon(Icons.phone_outlined),
                      ),
                    ),
                    if (_message.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: Colors.red.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Text(
                          _message,
                          style: const TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : _register,
                        icon: _isLoading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.app_registration),
                        label: Text(
                          _isLoading
                              ? tr('Registrierung läuft...', 'Registering...')
                              : tr(
                                  'Testzugang erstellen',
                                  'Create trial account',
                                ),
                        ),
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OcrCandidate {
  final String text;
  final double sizeScore;
  final int contentScore;

  const OcrCandidate({
    required this.text,
    required this.sizeScore,
    required this.contentScore,
  });

  double get totalScore => sizeScore + contentScore;
}

class OcrBoxCandidate {
  final String text;
  final double area;
  final double height;

  const OcrBoxCandidate({
    required this.text,
    required this.area,
    required this.height,
  });
}

class OcrCatalogMatch {
  final CatalogItem item;
  final String usedTerm;
  final String originalTerm;
  final int score;

  const OcrCatalogMatch({
    required this.item,
    required this.usedTerm,
    required this.originalTerm,
    required this.score,
  });
}

class MainSearchPage extends StatefulWidget {
  const MainSearchPage({super.key});

  @override
  State<MainSearchPage> createState() => _MainSearchPageState();
}

class _MainSearchPageState extends State<MainSearchPage>
    with WidgetsBindingObserver {
  static const int minSearchLen = 4;
  static const int manualSearchLen = 4;
  static const int maxOcrResultCount = 4;
  static const MethodChannel _downloadChannel = MethodChannel(
    'de.adleraufmasse.atool/downloads',
  );

  bool get _isIosOcrMode => defaultTargetPlatform == TargetPlatform.iOS;

  bool _pageLoading = false;
  bool _countLoading = true;
  bool _searchLoading = false;
  bool _showOcrSuggestions = false;
  bool _ocrSearchActive = false;
  bool _ocrCancelRequested = false;
  bool _resultChromeCollapsed = false;
  int _ocrRunId = 0;

  String _message = '';
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode(canRequestFocus: false);
  Timer? _debounce;
  Timer? _startupFocusGuardTimer;
  bool _ignoreSearchControllerChange = false;
  bool _licenseCheckInProgress = false;
  int _manualSearchRunId = 0;
  int _catalogIndexBuildRunId = 0;

  List<CatalogItem> _catalog = [];
  List<FrankeLabelMapping> _frankeLabelMappings = [];
  Set<String> _catalogManufacturers = {};
  List<CatalogSearchEntry> _catalogSearchIndex = [];
  Map<String, List<CatalogItem>> _ocrLookupIndex = {};
  List<CatalogItem> _results = [];
  String _activeHighlightTerm = '';
  bool _showSinkLabelMatchWarning = false;
  String _recognizedSinkLabelNumber = '';
  List<String> _ocrBoxTexts = [];
  int? _totalCount;
  int? _dwgDisplayCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPage();
    _searchController.addListener(_onSearchChanged);
    _searchFocusNode.addListener(_onSearchFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
      _startupFocusGuardTimer = Timer(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        _searchFocusNode.canRequestFocus = true;
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ocrCancelRequested = true;
    _ocrRunId++;
    _debounce?.cancel();
    _startupFocusGuardTimer?.cancel();
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_ensureActiveLicense());
    }
  }

  void _setSearchTextSilently(String text) {
    _debounce?.cancel();

    _ignoreSearchControllerChange = true;

    _searchController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );

    _ignoreSearchControllerChange = false;
  }

  Future<void> _initPage() async {
    unawaited(_ensureActiveLicense());
    unawaited(_loadDwgDisplayCount());
    unawaited(_loadInitialCatalog());
  }

  Future<void> _loadInitialCatalog() async {
    await _loadFrankeLabelMappings();

    await _loadCachedIndex().timeout(
      const Duration(seconds: 2),
      onTimeout: () => false,
    );

    unawaited(_refreshIndexFromServer(showBlockingLoader: false));
  }

  Future<bool> _ensureActiveLicense({bool force = false}) async {
    if (_licenseCheckInProgress) return true;
    if (!force && !await LicenseCheckPrefs.isCheckDue()) return true;

    _licenseCheckInProgress = true;

    try {
      final data = await ApiService.getLicenseStatus();

      if (data['success'] == true) {
        await LicenseCheckPrefs.markSuccessfulCheckNow();
        return true;
      }

      await AppStorage.clearTokens();

      if (!mounted) return false;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => LoginPage(
            initialErrorMessage: tr(
              'Sitzung oder Lizenz ist nicht mehr gültig. Bitte erneut anmelden.',
              'The session or license is no longer valid. Please log in again.',
            ),
          ),
        ),
        (route) => false,
      );

      return false;
    } catch (_) {
      if (await LicenseCheckPrefs.isWithinOfflineGracePeriod()) {
        return true;
      }

      await AppStorage.clearTokens();

      if (!mounted) return false;

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => LoginPage(
            initialErrorMessage: tr(
              'Lizenz konnte nicht geprüft werden. Bitte erneut anmelden.',
              'The license could not be verified. Please log in again.',
            ),
          ),
        ),
        (route) => false,
      );

      return false;
    } finally {
      _licenseCheckInProgress = false;
    }
  }

  Future<List<CatalogItem>> _parseCatalogItems(String responseBody) {
    return compute(_parseCatalogItemsInBackground, responseBody);
  }

  Future<void> _loadFrankeLabelMappings() async {
    try {
      final json = await rootBundle.loadString(
        AppConfig.frankeLabelMappingAsset,
      );
      final mappings = await compute(
        _parseFrankeLabelMappingsInBackground,
        json,
      );

      if (!mounted) return;

      _frankeLabelMappings = mappings;
    } catch (e) {
      debugPrint('FRANKE LABEL MAPPING LOAD FAILED: $e');
      _frankeLabelMappings = [];
    }
  }

  void _applyCatalogItems(List<CatalogItem> items) {
    _catalog = items;
    _catalogManufacturers = items
        .map((item) => _normalizeCatalogSearchText(item.manufacturer))
        .where((manufacturer) => manufacturer.isNotEmpty)
        .toSet();
    _totalCount = items.length;
    _pageLoading = false;
    _countLoading = _dwgDisplayCount == null && _totalCount == null;
    _message = '';
  }

  void _scheduleCatalogSearchIndexRebuild() {
    final runId = ++_catalogIndexBuildRunId;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _catalog.isEmpty) return;
      if (runId != _catalogIndexBuildRunId) return;

      unawaited(_rebuildCatalogSearchIndex(runId));
    });
  }

  Future<void> _rebuildCatalogSearchIndex(int runId) async {
    final catalogSnapshot = List<CatalogItem>.of(_catalog);
    final frankeLabelMappingsSnapshot = List<FrankeLabelMapping>.of(
      _frankeLabelMappings,
    );
    final index = await compute(
      _buildCatalogSearchIndexInBackground,
      _CatalogIndexBuildInput(
        catalog: catalogSnapshot,
        frankeLabelMappings: frankeLabelMappingsSnapshot,
      ),
    );

    if (!mounted || runId != _catalogIndexBuildRunId) return;

    _catalogSearchIndex = index.searchEntries;
    _ocrLookupIndex = index.ocrLookupIndex;

    debugPrint('CATALOG SEARCH INDEX READY: ${_catalogSearchIndex.length}');
    debugPrint('OCR LOOKUP INDEX READY: ${_ocrLookupIndex.length}');
  }

  Future<bool> _loadCachedIndex() async {
    try {
      final cachedJson = await CatalogCachePrefs.getCatalogJson();
      if (cachedJson == null || cachedJson.isEmpty) return false;

      final items = await _parseCatalogItems(cachedJson);
      if (!mounted) return false;

      setState(() {
        _applyCatalogItems(items);
      });
      _scheduleCatalogSearchIndexRebuild();

      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _refreshIndexFromServer({
    required bool showBlockingLoader,
  }) async {
    if (showBlockingLoader && mounted) {
      setState(() {
        _pageLoading = true;
        _message = '';
      });
    }

    try {
      final resp = await http
          .get(Uri.parse(AppConfig.catalogUrl))
          .timeout(const Duration(seconds: 12));
      final items = await _parseCatalogItems(resp.body);

      if (!mounted) return;

      setState(() {
        _applyCatalogItems(items);
      });
      _scheduleCatalogSearchIndexRebuild();

      unawaited(
        CatalogCachePrefs.setCatalogJson(resp.body).catchError((_) {
          // Cache ist nur Komfort. Die App darf beim Start nicht daran hängen.
        }),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (_catalog.isEmpty) {
          _message = tr(
            'Katalog konnte nicht geladen werden.',
            'Could not load the catalog.',
          );
        }
        _pageLoading = false;
        _countLoading = false;
      });
    }
  }

  void _onSearchChanged() {
    if (_ignoreSearchControllerChange) {
      return;
    }

    _debounce?.cancel();
    final q = _searchController.text.trim();
    _manualSearchRunId++;

    if (q.length < manualSearchLen) {
      setState(() {
        _results = [];
        _searchLoading = false;
        _activeHighlightTerm = '';
        _showSinkLabelMatchWarning = false;
        _recognizedSinkLabelNumber = '';
        _resultChromeCollapsed = false;
        _message = '';
      });
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 450), () {
      _handleSearchDirect(q);
    });
  }

  void _onSearchFocusChanged() {
    if (!mounted) return;

    if (_searchFocusNode.hasFocus) {
      if (!_resultChromeCollapsed) return;
      setState(() {
        _resultChromeCollapsed = false;
      });
      return;
    }

    if (_results.isEmpty || _searchLoading || _resultChromeCollapsed) return;

    setState(() {
      _resultChromeCollapsed = true;
    });
  }

  String _safeDxfFileName(String filename) {
    final base = filename.trim().isEmpty ? 'download' : filename.trim();
    return '$base.dxf';
  }

  String _normalizeForSearch(String input) {
    return _normalizeCatalogSearchText(input);
  }

  Set<String> _buildCompareVariants(String input) {
    final base = _normalizeForSearch(input);
    var rawBase = input.toLowerCase().trim();

    const replacements = {
      '\u00e4': 'a',
      '\u00f6': 'o',
      '\u00fc': 'u',
      '\u00df': 'ss',
    };
    replacements.forEach((key, value) {
      rawBase = rawBase.replaceAll(key, value);
    });

    rawBase = rawBase.replaceAll(RegExp(r'[^a-z0-9/_. -]'), '');
    rawBase = rawBase.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (base.isEmpty && rawBase.isEmpty) return {};

    final variants = <String>{
      base,
      rawBase,
      base.replaceAll('-', ' '),
      base.replaceAll('/', ' '),
      base.replaceAll('.', ' '),
      base.replaceAll(RegExp(r'\s+'), ' ').trim(),
      base.replaceAll(RegExp(r'[-/.\s_]'), ''),
    };

    final extra = <String>{};

    for (final v in variants) {
      final compact = v.replaceAll(' ', '');

      // rein numerisch: führende Nullen entfernen
      if (RegExp(r'^0+\d+$').hasMatch(compact)) {
        final stripped = compact.replaceFirst(RegExp(r'^0+'), '');
        if (stripped.isNotEmpty) {
          extra.add(stripped);

          // Blanco-Fall: 00xxxxxx -> xxxxxx, wenn echte Nummer mit 5 beginnt
          if (compact.startsWith('00') && stripped.startsWith('5')) {
            extra.add(stripped);
          }
        }
      }

      if (RegExp(r'^\d{5,7}0+$').hasMatch(compact)) {
        final strippedTrailingZeros = compact.replaceFirst(RegExp(r'0+$'), '');
        if (strippedTrailingZeros.length >= 4) {
          extra.add(strippedTrailingZeros);
        }
      }

      final numericPrefixWithSuffix = RegExp(
        r'^(\d{4,5})\d*[a-z].*$',
      ).firstMatch(compact);
      if (numericPrefixWithSuffix != null) {
        final prefix = numericPrefixWithSuffix.group(1);
        if (prefix != null) extra.add(prefix);
      }

      if (RegExp(r'(?=.*[a-z])(?=.*\d)').hasMatch(compact)) {
        extra.add(compact.replaceAll('o', '0'));
        extra.add(compact.replaceAll('0', 'o'));
      }

      // numerische Tokens innerhalb eines Ausdrucks normalisieren
      final tokenNormalized = v
          .split(RegExp(r'\s+'))
          .map((part) {
            if (RegExp(r'^0+\d+$').hasMatch(part)) {
              final stripped = part.replaceFirst(RegExp(r'^0+'), '');
              return stripped.isEmpty ? '0' : stripped;
            }
            return part;
          })
          .join(' ')
          .trim();

      if (tokenNormalized.isNotEmpty) {
        extra.add(tokenNormalized);
        extra.add(tokenNormalized.replaceAll(RegExp(r'[-/.\s_]'), ''));
      }
    }

    variants.addAll(extra);

    return variants.where((e) => e.isNotEmpty).toSet();
  }

  Set<String> _buildOcrLookupKeys(String input) {
    final keys = <String>{};

    for (final variant in _buildCompareVariants(input)) {
      final normalized = _normalizeForSearch(variant);
      final compact = normalized.replaceAll(RegExp(r'[^a-z0-9]'), '');

      if (normalized.length >= minSearchLen) {
        keys.add(normalized);
      }

      if (compact.length >= minSearchLen) {
        keys.add(compact);
      }

      if (RegExp(r'(?=.*[a-z])(?=.*\d)').hasMatch(compact)) {
        keys.add(compact.replaceAll('o', '0'));
        keys.add(compact.replaceAll('0', 'o'));
      }

      for (final match in RegExp(
        r'\b([a-z]{2,5})\s+(\d{2,4})(?:[\s-]+(\d{1,4}))?',
      ).allMatches(normalized)) {
        final prefix = match.group(1);
        final number = match.group(2);
        final suffix = match.group(3);

        if (prefix == null || number == null) continue;

        keys.add('$prefix $number');
        keys.add('$prefix$number');

        if (suffix != null && suffix.isNotEmpty) {
          keys.add('$prefix $number-$suffix');
          keys.add('$prefix$number$suffix');
        }
      }
    }

    return keys.where((e) => e.length >= minSearchLen).toSet();
  }

  Set<String> _buildExactArticleNumberKeys(String input) {
    final keys = <String>{};

    for (final variant in _buildCompareVariants(input)) {
      final normalized = _normalizeForSearch(variant);
      final compact = normalized.replaceAll(RegExp(r'[^a-z0-9]'), '');

      if (normalized.length >= manualSearchLen) keys.add(normalized);
      if (compact.length >= manualSearchLen) keys.add(compact);
    }

    return keys;
  }

  bool _hasFrankeSinkLabelNumber(String rawText, List<OcrBoxCandidate> boxes) {
    return extractFrankeSinkLabelNumbers(
      [rawText, ...boxes.map((e) => e.text)].join(' '),
    ).isNotEmpty;
  }

  bool _hasBlancoSinkLabelNumber(String rawText, List<OcrBoxCandidate> boxes) {
    return extractBlancoSinkLabelNumbers(
      [rawText, ...boxes.map((e) => e.text)].join(' '),
    ).isNotEmpty;
  }

  bool _hasBoraModelNumber(String rawText, List<OcrBoxCandidate> boxes) {
    return extractBoraModelNumbers(
      [rawText, ...boxes.map((e) => e.text)].join(' '),
    ).isNotEmpty;
  }

  bool _isFrankeLabelSearchTerm(String term) {
    if (_frankeLabelMappings.isEmpty) return false;

    final termKeys = _buildExactArticleNumberKeys(term);
    if (termKeys.isEmpty) return false;

    for (final mapping in _frankeLabelMappings) {
      final labelKeys = _buildExactArticleNumberKeys(mapping.label);
      if (labelKeys.any(termKeys.contains)) {
        return true;
      }
    }

    return false;
  }

  bool _isBlancoLabelSearchTerm(String term) {
    return extractBlancoSinkLabelNumbers(term).isNotEmpty;
  }

  bool _isBoraLabelSearchTerm(String term) {
    return extractBoraModelNumbers('Model: $term').isNotEmpty;
  }

  bool _isSinkLabelSearchTerm(String term) {
    return _isFrankeLabelSearchTerm(term) ||
        _isBlancoLabelSearchTerm(term) ||
        _isBoraLabelSearchTerm(term);
  }

  String _recognizedSinkLabelNumberForSearchTerm(String term) {
    return recognizedSinkLabelNumber(term) ?? term.trim();
  }

  String _labelRuleNameForSearchTerm(String term) {
    if (extractFrankeSinkLabelNumbers(term).isNotEmpty) return 'franke';
    if (extractBlancoSinkLabelNumbers(term).isNotEmpty) return 'blanco';
    if (extractBoraModelNumbers('Model: $term').isNotEmpty) return 'bora';
    return '';
  }

  void _logSearchQuality({
    required String event,
    required String searchType,
    required String term,
    String usedTerm = '',
    String labelRule = '',
    String recognizedLabel = '',
    int? resultCount,
    List<CatalogItem> results = const [],
    List<String> ocrTerms = const [],
  }) {
    final topResults = results.take(maxOcrResultCount).toList();

    unawaited(
      http
          .post(
            Uri.parse(AppConfig.logUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'event': event,
              'search_type': searchType,
              'term': term,
              'used_term': usedTerm.isEmpty ? term : usedTerm,
              'label_rule': labelRule,
              'recognized_label': recognizedLabel,
              'found': (resultCount ?? results.length) > 0 ? 1 : 0,
              'result_count': resultCount ?? results.length,
              'result_ids': topResults.map((item) => item.id).join('|'),
              'result_names': topResults.map((item) => item.basename).join('|'),
              'ocr_terms': ocrTerms.take(12).join('|'),
            }),
          )
          .catchError((_) {
            // Qualitaetslogging darf die Suche nie beeinflussen.
            return http.Response('', 0);
          }),
    );
  }

  List<CatalogItem> _localSearch(String q) {
    final queryVariants = _buildCompareVariants(q);
    if (queryVariants.isEmpty) return [];

    if (_catalogSearchIndex.isEmpty) return [];

    final normalizedVariants = queryVariants
        .map(_normalizeForSearch)
        .where((e) => e.length >= manualSearchLen)
        .toSet();
    final compactVariants = normalizedVariants
        .map((e) => e.replaceAll(RegExp(r'[^a-z0-9]'), ''))
        .where((e) => e.length >= manualSearchLen)
        .toSet();

    final results = <CatalogItem>[];
    final seen = <String>{};

    for (final entry in _catalogSearchIndex) {
      var matched = false;

      for (final variant in normalizedVariants) {
        if (entry.manualSearchText.contains(variant)) {
          matched = true;
          break;
        }
      }

      if (!matched) {
        for (final variant in compactVariants) {
          if (entry.manualCompactText.contains(variant)) {
            matched = true;
            break;
          }
        }
      }

      if (!matched) continue;

      final itemKey = '${entry.item.id}|${entry.item.basename}';
      if (seen.add(itemKey)) {
        results.add(entry.item);
        if (results.length >= 50) break;
      }
    }

    return results;
  }

  List<String> _buildSearchFallbackTerms(String input) {
    final cleaned = input.trim().replaceAll(RegExp(r'\s+'), ' ');

    if (cleaned.isEmpty) return [];

    final withoutManufacturer = _removeManufacturerTokensFromOcrTerm(cleaned);

    final parts =
        (withoutManufacturer.isNotEmpty ? withoutManufacturer : cleaned)
            .split(' ')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();

    final terms = <String>[];

    void addTerm(String term) {
      final cleanedTerm = term.trim();

      if (cleanedTerm.length >= minSearchLen && !terms.contains(cleanedTerm)) {
        terms.add(cleanedTerm);
      }
    }

    // 1. Erst komplette Eingabe testen
    addTerm(cleaned);

    // 2. Dann längste zusammenhängende Teilstücke testen
    // Beispiel:
    // "Artikel KM 6023 EDST"
    // zuerst: "Artikel KM 6023", "KM 6023 EDST"
    // dann:   "Artikel KM", "KM 6023", "6023 EDST"
    // dann:   "Artikel", "KM", "6023", "EDST"
    for (int len = parts.length - 1; len >= 1; len--) {
      for (int start = 0; start <= parts.length - len; start++) {
        final term = parts.sublist(start, start + len).join(' ');
        addTerm(term);
      }
    }

    return terms;
  }

  Future<void> _showOcrPicker() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(tr('Kamera', 'Camera')),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(tr('Galerie', 'Gallery')),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );

    if (source == null) return;
    await _runLocalOcr(source);
  }

  String _cleanOcrLine(String input) {
    var s = input.trim();

    s = s.replaceAll('|', 'I');
    s = s.replaceAll(RegExp(r'[,;:]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    s = s.replaceAll(RegExp(r'[^A-Za-z0-9.\-_/ ]'), '');

    return s.trim();
  }

  String? _extractPreferredArticleNumber(String rawText) {
    final lines = rawText
        .split(RegExp(r'[\r\n]+'))
        .map((e) => _cleanOcrLine(e))
        .where((e) => e.isNotEmpty)
        .toList();

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lower = line.toLowerCase();

      if (lower.contains('artikel')) {
        // zuerst in derselben Zeile nach langer Zahl suchen
        final sameLineMatches = RegExp(r'\d{6,}').allMatches(line);
        for (final match in sameLineMatches) {
          final num = match.group(0);
          if (num != null && num.isNotEmpty) {
            return num;
          }
        }

        // dann in den nächsten 2 Zeilen suchen
        for (int j = i + 1; j <= i + 2 && j < lines.length; j++) {
          final nextLine = lines[j];
          final nextMatches = RegExp(r'\d{6,}').allMatches(nextLine);
          for (final match in nextMatches) {
            final num = match.group(0);
            if (num != null && num.isNotEmpty) {
              return num;
            }
          }
        }
      }
    }

    return null;
  }

  String _normalizeOcrSearchTerm(String input) {
    final cleaned = _cleanOcrLine(input);
    if (cleaned.isEmpty) return '';

    final parts = cleaned
        .split(' ')
        .map((part) {
          final p = part.trim();

          // nur bei rein numerischen Teilen führende Nullen entfernen
          if (RegExp(r'^0+\d+$').hasMatch(p)) {
            final stripped = p.replaceFirst(RegExp(r'^0+'), '');
            return stripped.isEmpty ? '0' : stripped;
          }

          return p;
        })
        .where((e) => e.isNotEmpty)
        .toList();

    return parts.join(' ').trim();
  }

  List<OcrBoxCandidate> _extractOcrBoxCandidatesSorted(
    RecognizedText recognizedText,
  ) {
    final candidates = <OcrBoxCandidate>[];

    for (final block in recognizedText.blocks) {
      final blockText = _cleanOcrLine(block.text);
      final blockBox = block.boundingBox;
      final blockArea = blockBox.width * blockBox.height;

      if (blockText.isNotEmpty && blockArea > 0) {
        candidates.add(
          OcrBoxCandidate(
            text: blockText,
            area: blockArea,
            height: blockBox.height,
          ),
        );
      }

      for (final line in block.lines) {
        final lineText = _cleanOcrLine(line.text);
        final lineBox = line.boundingBox;
        final lineArea = lineBox.width * lineBox.height;

        if (lineText.isNotEmpty && lineArea > 0) {
          candidates.add(
            OcrBoxCandidate(
              text: lineText,
              area: lineArea,
              height: lineBox.height,
            ),
          );
        }
      }
    }

    final deduped = <String, OcrBoxCandidate>{};

    for (final c in candidates) {
      final key = _normalizeOcrSearchTerm(c.text);
      if (key.isEmpty) continue;

      final existing = deduped[key];
      if (existing == null ||
          c.height > existing.height ||
          (c.height == existing.height && c.area > existing.area)) {
        deduped[key] = OcrBoxCandidate(
          text: key,
          area: c.area,
          height: c.height,
        );
      }
    }

    final sorted = deduped.values.toList()
      ..sort((a, b) {
        final heightCompare = b.height.compareTo(a.height);
        if (heightCompare != 0) return heightCompare;

        return b.area.compareTo(a.area);
      });

    return sorted;
  }

  bool _looksLikePureManufacturerBox(String text) {
    final normalized = _normalizeForSearch(text);
    if (normalized.isEmpty) return false;

    final parts = normalized
        .split(RegExp(r'\s+'))
        .where((e) => e.trim().isNotEmpty)
        .toList();

    // Nur einzelne Wörter können reine Hersteller-Boxen sein.
    // Wichtig: "MONO" darf NICHT automatisch als Hersteller gelten.
    if (parts.length != 1) return false;

    if (_isManufacturerOcrToken(parts.first)) {
      return true;
    }

    // Zusätzlich gegen Hersteller aus dem Katalog prüfen. Das vorbereitete Set
    // hält die OCR-Kandidatenbildung auch bei großen Katalogen reaktionsschnell.
    return _catalogManufacturers.contains(normalized);
  }

  bool _isManufacturerOcrToken(String token) {
    final normalized = _normalizeForSearch(token);

    const manufacturers = {
      'aeg',
      'amica',
      'approsine',
      'bauknecht',
      'beko',
      'benthaus',
      'berbel',
      'blanco',
      'blaupunkt',
      'bomann',
      'bora',
      'bosch',
      'brandano',
      'candy',
      'caressi',
      'electrolux',
      'elleci',
      'flamec',
      'fors',
      'foster',
      'franke',
      'gaggenau',
      'gorenje',
      'grohe',
      'haier',
      'hansgrohe',
      'ignis',
      'ikea',
      'junker',
      'kaiser',
      'laufen',
      'laurus',
      'lavabo',
      'lorreine',
      'luisina',
      'miele',
      'naber',
      'neff',
      'novy',
      'elica',
      'privileg',
      'oranier',
      'progress',
      'pyramis',
      'reginox',
      'respekta',
      'rodi',
      'schock',
      'siemens',
      'silverline',
      'smeg',
      'suter',
      'systemceram',
      'teka',
      'villeroy & boch',
      'vzug',
      'wesco',
      'whirlpool',
      'zanker',
      'zanussi',
    };

    return manufacturers.contains(normalized);
  }

  String _removeManufacturerTokensFromOcrTerm(String input) {
    final parts = input
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.trim().isNotEmpty)
        .where((part) => !_isManufacturerOcrToken(part))
        .toList();

    return parts.join(' ').trim();
  }

  List<CatalogItem> _localOcrSearch(String q) {
    final queryVariants = _buildCompareVariants(q);
    if (queryVariants.isEmpty) return [];

    bool matches(CatalogItem item) {
      final itemFields = <String>[
        item.basename,
        item.id,
        item.dwgPath ?? '',
        item.dxfPath ?? '',
        item.jpgPath ?? '',
        // bewusst OHNE item.manufacturer
        // bewusst OHNE item.type
      ];

      for (final field in itemFields) {
        final fieldVariants = _buildCompareVariants(field);

        for (final qv in queryVariants) {
          final compactQ = qv.replaceAll(RegExp(r'[^a-z0-9]'), '');

          for (final fv in fieldVariants) {
            final compactF = fv.replaceAll(RegExp(r'[^a-z0-9]'), '');

            // Zahlen und formatierte Artikelnummern strenger, aber kompakt vergleichen.
            // Beispiele:
            // 127.0658.064 == 1270658064
            // 8250573-1 == 82505731
            if (compactQ.length >= 5 && RegExp(r'\d').hasMatch(compactQ)) {
              if (fv == qv ||
                  fv.contains(qv) ||
                  compactF == compactQ ||
                  compactF.contains(compactQ)) {
                return true;
              }
            } else {
              if (fv.contains(qv)) {
                return true;
              }
            }
          }
        }
      }

      return false;
    }

    return _catalog.where(matches).take(50).toList();
  }

  List<CatalogItem> _lookupOcrIndex(String q, {int limit = 20}) {
    if (_ocrLookupIndex.isEmpty) return [];

    final results = <CatalogItem>[];
    final seen = <String>{};

    for (final key in _buildOcrLookupKeys(q)) {
      final items = _ocrLookupIndex[key];
      if (items == null) continue;

      for (final item in items) {
        final itemKey = '${item.id}|${item.basename}';
        if (seen.contains(itemKey)) continue;

        seen.add(itemKey);
        results.add(item);

        if (results.length >= limit) {
          return results;
        }
      }
    }

    return results;
  }

  List<CatalogItem> _fastLocalOcrSearch(String q, {int limit = 20}) {
    final indexedResults = _lookupOcrIndex(q, limit: limit);
    if (indexedResults.isNotEmpty) {
      return indexedResults;
    }

    final qNorm = _normalizeForSearch(q);
    final qCompact = qNorm.replaceAll(RegExp(r'[^a-z0-9]'), '');

    if (qCompact.length < minSearchLen) return [];

    if (_catalogSearchIndex.isEmpty) {
      return _localOcrSearch(q).take(limit).toList();
    }

    final results = <CatalogItem>[];
    final seen = <String>{};

    for (final entry in _catalogSearchIndex) {
      var matched = false;

      // Normaler schneller Treffer:
      // Catalog enthält OCR-Begriff.
      if (entry.searchText.contains(qNorm) ||
          entry.compactText.contains(qCompact)) {
        matched = true;
      }

      // Neuer wichtiger Fall:
      // OCR-Begriff enthält Catalog-Feld.
      // Beispiel:
      // OCR:     KMDA 7473 FL-U Silence
      // Catalog: KMDA 7473 FL-U
      if (!matched) {
        for (final fieldText in entry.fieldTexts) {
          if (fieldText.length >= minSearchLen && qNorm.contains(fieldText)) {
            matched = true;
            break;
          }
        }
      }

      if (!matched) {
        for (final fieldCompact in entry.fieldCompacts) {
          if (fieldCompact.length >= minSearchLen &&
              qCompact.contains(fieldCompact)) {
            matched = true;
            break;
          }
        }
      }

      if (!matched) continue;

      final key = '${entry.item.id}|${entry.item.basename}';
      if (seen.contains(key)) continue;

      seen.add(key);
      results.add(entry.item);

      if (results.length >= limit) {
        break;
      }
    }

    return results;
  }

  String _compactForSmartOcr(String input) {
    return _normalizeForSearch(input).replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  bool _isIgnoredSmartOcrToken(String token) {
    final t = _normalizeForSearch(token);
    if (t.isEmpty) return true;

    if (_looksLikePureManufacturerBox(t)) return true;

    const ignored = {
      'typ',
      'type',
      'modell',
      'model',
      'artikel',
      'art',
      'nr',
      'no',
      'bestell',
      'serial',
      'serie',
      'made',
      'germany',
      'deutschland',
      'transport',
      'route',
      'versender',
      'empfaenger',
      'empfanger',
      'menge',
      'liefer',
      'liefermenge',
      'beschreibung',
      'gewicht',
      'packmittel',
      'st',
      'ce',
      'en',
      'ukca',
      'dop',
      'pwd',
      'pro',
      'fr',
      'de',
      'eu',
      'in',
    };

    return ignored.contains(t);
  }

  bool _looksLikeStrongArticleToken(String token) {
    final compact = _compactForSmartOcr(token);
    if (compact.length < 3) return false;

    final hasLetter = RegExp(r'[a-z]').hasMatch(compact);
    final hasDigit = RegExp(r'\d').hasMatch(compact);

    // Beispiele: EH601HFB1E, D100L, KM6023, 521841, 5402
    if (hasLetter && hasDigit && compact.length >= 4) return true;
    if (!hasLetter && hasDigit && compact.length >= minSearchLen) return true;

    return false;
  }

  bool _looksLikeCertificationNoiseCandidate(String value) {
    final normalized = _normalizeForSearch(value);
    final compact = _compactForSmartOcr(value);

    if (RegExp(
      r'^\b(en|ce|ukca|dop|pwd)\b\s*[:\-]?\s*\d{1,5}\b',
    ).hasMatch(normalized)) {
      return true;
    }

    if (RegExp(r'^(en|ce|ukca|dop|pwd)\d{1,5}$').hasMatch(compact)) {
      return true;
    }

    return false;
  }

  bool _looksLikeLogisticsNoiseCandidate(String value) {
    final normalized = _normalizeForSearch(value);
    final compact = _compactForSmartOcr(value);

    if (_looksLikeCertificationNoiseCandidate(value)) return true;

    final hasProductPattern =
        RegExp(r'\b[a-z]{2,5}\s+\d{2,4}\b').hasMatch(normalized) ||
        RegExp(r'^[a-z]{1,5}\d{3,}[a-z0-9]{0,5}$').hasMatch(compact);

    if (hasProductPattern) return false;

    final longNumberCount = RegExp(r'\b\d{8,}\b').allMatches(normalized).length;
    if (longNumberCount >= 2) return true;

    return RegExp(
      r'\b(auftrag|aufrags|bestell|komm|liefer|liefermenge|pos|menge|route|laiernstr|logistik|zentrum|empfaenger|schoch|de-?\d{5})\b',
    ).hasMatch(normalized);
  }

  int _smartOcrCandidateRank(String value) {
    final normalized = _normalizeForSearch(value);
    final compact = _compactForSmartOcr(value);

    if (_looksLikeCertificationNoiseCandidate(value)) {
      return 9;
    }

    if (RegExp(
      r'^\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+$',
    ).hasMatch(normalized)) {
      return 0;
    }

    // Kurze Produktcodes wie CNG 211, KMDA 7473, VG264220 bevorzugen.
    if (RegExp(
          r'^[a-z]{2,5}\s+\d{2,4}(?:[\s-]+[a-z0-9]{1,4})?$',
        ).hasMatch(normalized) ||
        RegExp(r'^[a-z]{1,5}\d{3,}[a-z0-9]{0,5}$').hasMatch(compact)) {
      return 1;
    }

    if (_tokenizeSmartOcr(value).any(_looksLikeStrongArticleToken)) {
      return 2;
    }

    if (_looksLikeLogisticsNoiseCandidate(value)) {
      return 9;
    }

    return 5;
  }

  bool _looksLikeModelCandidateTokens(List<String> tokens) {
    var hasModelLetters = false;
    var hasModelNumber = false;

    for (final token in tokens) {
      final compact = _compactForSmartOcr(token);
      if (compact.isEmpty) continue;

      final hasLetter = RegExp(r'[a-z]').hasMatch(compact);
      final hasDigit = RegExp(r'\d').hasMatch(compact);

      // EH601HFB1E, D100L, ICE07
      if (hasLetter && hasDigit && compact.length >= 4) {
        return true;
      }

      // KMDA, MONO, FLU usw.
      if (hasLetter && compact.length >= 2) {
        hasModelLetters = true;
      }

      // 7473, 6023 usw.
      if (!hasLetter && hasDigit && compact.length >= 4) {
        hasModelNumber = true;
      }
    }

    // Beispiel: KMDA + 7473 + FL-U
    return hasModelLetters && hasModelNumber;
  }

  List<String> _tokenizeSmartOcr(String input) {
    final normalized = _normalizeOcrSearchTerm(input);

    return normalized
        .split(RegExp(r'[\s,;:(){}\[\]|]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .where((e) => !_isIgnoredSmartOcrToken(e))
        .toList();
  }

  List<String> _buildIosExtraOcrCandidates(
    String rawText,
    List<OcrBoxCandidate> boxes,
  ) {
    final result = <String>{};

    void addCandidate(String value) {
      final normalized = _normalizeOcrSearchTerm(value);
      if (normalized.length < minSearchLen) return;

      // iOS-Zusatzlogik soll keine langen Barcodes übernehmen.
      if (_isLikelyBarcodeNumber(normalized)) {
        debugPrint('iOS EXTRA OCR BARCODE SKIPPED: $normalized');
        return;
      }

      if (_isManufacturerOcrToken(normalized)) return;

      final tokens = _tokenizeSmartOcr(normalized);
      if (tokens.isEmpty) return;

      final hasDigit = RegExp(r'\d').hasMatch(normalized);
      final hasStrongToken = tokens.any(_looksLikeStrongArticleToken);
      final looksLikeModel = _looksLikeModelCandidateTokens(tokens);

      // Nur Begriffe übernehmen, die wie Artikel-/Modellnummern aussehen.
      if (hasDigit || hasStrongToken || looksLikeModel) {
        result.add(normalized);
      }
    }

    final sources = <String>[
      ...rawText.split(RegExp(r'[\r\n]+')),
      ...boxes.map((e) => e.text),
    ];

    for (final source in sources) {
      final cleanSource = source.trim();
      if (cleanSource.isEmpty) continue;

      // Ganze Zeile/Box übernehmen.
      addCandidate(cleanSource);

      final tokens = _tokenizeSmartOcr(cleanSource);
      if (tokens.length < 2) continue;

      // iOS trennt OCR manchmal ungünstig.
      // Deshalb aus Zeilen zusätzliche 2er- bis 5er-Kombinationen bilden.
      for (int i = 0; i < tokens.length; i++) {
        for (int len = 2; len <= 5; len++) {
          if (i + len > tokens.length) continue;

          final part = tokens.sublist(i, i + len).join(' ');
          addCandidate(part);
        }
      }
    }

    return result.toList();
  }

  Future<({String path, bool isTemporary})> _prepareOcrInputImage(
    String originalPath,
  ) async {
    const maxOcrImageSide = 1800;
    final result = await compute(_prepareOcrInputImageInBackground, {
      'path': originalPath,
      'maxSide': maxOcrImageSide,
    });
    final error = result['error'];
    if (error != null) debugPrint('OCR RESIZE FAILED: $error');

    return (
      path: result['path']! as String,
      isTemporary: result['isTemporary']! as bool,
    );
  }

  Future<List<({String path, int rotation})>> _buildFallbackOcrImageVariants(
    String originalPath,
  ) async {
    // Etiketten stehen manchmal auf dem Kopf oder seitlich. Die aufwendige
    // Bildverarbeitung darf den Abbrechen-Button nicht blockieren.
    final variants = await compute(
      _buildFallbackOcrImageVariantsInBackground,
      originalPath,
    );

    return variants
        .map(
          (variant) => (
            path: variant['path']! as String,
            rotation: variant['rotation']! as int,
          ),
        )
        .toList();
  }

  List<String> _buildDomainOcrCandidates(
    String rawText,
    List<OcrBoxCandidate> boxes,
  ) {
    final result = <String>[];
    final sources = <String>[
      ...rawText.split(RegExp(r'[\r\n]+')),
      ...boxes.map((e) => e.text),
    ];

    void add(String value) {
      final cleaned = _cleanOcrLine(value);
      if (cleaned.length < minSearchLen) return;
      if (_isLikelyBarcodeNumber(cleaned)) return;
      if (!result.contains(cleaned)) result.add(cleaned);
    }

    String cleanupProductLine(String value) {
      var s = _cleanOcrLine(value);
      s = s.replaceAll(
        RegExp(
          r'\b(RE|RV|SG|SWZ|CNS|AF|SPULE|SPUEL|SPUL|SINK|EXC|REV|MRU|MB|NERO|PURO)\b',
          caseSensitive: false,
        ),
        ' ',
      );
      s = s.replaceAll(RegExp(r'\b\d+\s*1/2"?\b'), ' ');
      s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      return s;
    }

    for (final source in sources) {
      final line = _cleanOcrLine(source);
      if (line.isEmpty) continue;

      final compactLine = line.replaceAll(RegExp(r'\s+'), ' ');

      for (final pattern in [
        RegExp(
          r'\b(?:E-NR|E NR|MODEL DESIGNATION|MODEL|MODELLNAME|MODELL|MOD|TYPE|TYP|PRODUCT NO|PRODUCT NR|ARTIKELNR|ARTIKELNUMMER)\b\.?\s*[:\-]?\s*([A-Z0-9][A-Z0-9 ._\/\-]{2,24})',
          caseSensitive: false,
        ),
        RegExp(
          r'\b(?:V&B\s*-\s*ARTIKELNUMMER|V B\s*-\s*ARTIKELNUMMER)\b\s*([A-Z0-9][A-Z0-9 ._\/\-]{2,24})',
          caseSensitive: false,
        ),
      ]) {
        final match = pattern.firstMatch(compactLine);
        final value = match?.group(1);
        if (value == null) continue;

        final withoutSuffix = value
            .replaceFirst(RegExp(r'\s*/\s*\d{1,3}\b'), '')
            .replaceFirst(
              RegExp(
                r'\b(FD|Z-NR|TYPE|TYP|SERIAL|SN)\b.*',
                caseSensitive: false,
              ),
              '',
            )
            .trim();
        add(withoutSuffix);
      }

      final descriptionMatch = RegExp(
        r'\b(?:BESCHREIBUNG|DESCRIPTION)\b\s*([A-Z]{2,5}\s+\d{2,4}(?:[- ]\d{2,4})?)',
        caseSensitive: false,
      ).firstMatch(compactLine);
      final descriptionCode = descriptionMatch?.group(1);
      if (descriptionCode != null) add(descriptionCode);

      for (final match in RegExp(
        r'\b([A-ZÄÖÜ]{3,}\s+\d+[A-Z]?(?:[- ]?[A-Z0-9]{1,4})?)\b',
        caseSensitive: false,
      ).allMatches(compactLine)) {
        final value = match.group(1);
        if (value == null) continue;

        final cleaned = cleanupProductLine(value);
        if (_looksLikeCertificationNoiseCandidate(cleaned)) continue;
        add(cleaned);
      }

      for (final match in RegExp(
        r'\b([A-Z][A-Z0-9]{1,5}\s+\d{2,4}(?:[- ]?[A-Z0-9]{1,4}){0,3})\b',
        caseSensitive: false,
      ).allMatches(compactLine)) {
        final value = match.group(1);
        if (value != null) add(cleanupProductLine(value));
      }

      for (final match in RegExp(
        r'\b([A-Z]{2,5}\d{3,6}[A-Z0-9]{0,4})\b',
        caseSensitive: false,
      ).allMatches(compactLine)) {
        final value = match.group(1);
        if (value != null) add(value);
      }
    }

    return result;
  }

  List<String> _buildSmartOcrCandidates(
    String rawText,
    List<OcrBoxCandidate> boxes,
  ) {
    final candidates = <String>[];

    void addCandidate(String value) {
      final cleaned = _normalizeOcrSearchTerm(value);
      if (cleaned.length < minSearchLen) return;

      // Nur iOS:
      // Lange reine Barcode-/Seriennummern nicht als Smart-Kandidat verwenden.
      if (_isIosOcrMode && _isLikelyBarcodeNumber(cleaned)) {
        debugPrint('iOS SMART OCR BARCODE SKIPPED: $cleaned');
        return;
      }

      // Sehr lange Zeilen sind meist Beschreibungen, Adressen oder Liefertexte.
      // Kurze Kombinationen wie "MONO D100L" bleiben erlaubt.
      if (cleaned.length > 36) return;
      if (_looksLikeCertificationNoiseCandidate(cleaned)) return;
      if (_looksLikeLogisticsNoiseCandidate(cleaned)) return;

      if (!candidates.contains(cleaned)) {
        candidates.add(cleaned);
      }

      final normalizedLower = _normalizeForSearch(cleaned);
      if (RegExp(r'\bcng\s*211\b').hasMatch(normalizedLower) &&
          !normalizedLower.contains('86')) {
        addCandidate('CNG 211-86');
      }

      final compact = cleaned.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      if (RegExp(r'(?=.*[A-Za-z])(?=.*\d)').hasMatch(compact)) {
        final zeroVariant = compact.replaceAll('O', '0').replaceAll('o', '0');
        final letterVariant = compact.replaceAll('0', 'O');

        for (final variant in [zeroVariant, letterVariant]) {
          if (variant.length >= minSearchLen && !candidates.contains(variant)) {
            candidates.add(variant);
          }
        }
      }
    }

    for (final candidate in _buildDomainOcrCandidates(rawText, boxes)) {
      addCandidate(candidate);
    }

    for (final box in boxes) {
      final boxText = _normalizeOcrSearchTerm(box.text);
      if (boxText.isEmpty) continue;

      if (_looksLikePureManufacturerBox(boxText)) {
        continue;
      }

      final tokens = _tokenizeSmartOcr(boxText);

      // Ganze Box verwenden, wenn sie nicht zu lang ist und mindestens ein starker Token drin ist.
      if (tokens.any(_looksLikeStrongArticleToken) ||
          _looksLikeModelCandidateTokens(tokens)) {
        addCandidate(tokens.join(' '));
      }

      // 3er- und 2er-Kombinationen zuerst erzeugen.
      // Beispiel: "MONO D100L" gewinnt später gegen nur "D100L".
      for (int len = 3; len >= 2; len--) {
        for (int start = 0; start <= tokens.length - len; start++) {
          final slice = tokens.sublist(start, start + len);

          if (slice.any(_looksLikeStrongArticleToken) ||
              _looksLikeModelCandidateTokens(slice)) {
            addCandidate(slice.join(' '));
          }
        }
      }

      // Einzelne starke Tokens.
      for (final token in tokens) {
        if (_looksLikeStrongArticleToken(token)) {
          addCandidate(token);
        }
      }

      // Formatierte Nummern wie 127.0658.064 zusätzlich ziehen.
      for (final match in RegExp(
        r'\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+',
      ).allMatches(boxText)) {
        final value = match.group(0);
        if (value != null) addCandidate(value);
      }
    }

    // iOS-Zusatzkandidaten NACH der Box-Schleife ergänzen.
    // Android bleibt unverändert.
    if (_isIosOcrMode) {
      for (final candidate in _buildIosExtraOcrCandidates(rawText, boxes)) {
        addCandidate(candidate);
      }
    }

    // Auch aus dem Gesamttext Kandidaten ziehen.
    final allText = [rawText, ...boxes.map((e) => e.text)].join(' ');

    for (final match in RegExp(
      r'\b(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{4,}\b',
    ).allMatches(allText)) {
      final value = match.group(0);
      if (value != null) addCandidate(value);
    }

    for (final match in RegExp(
      r'\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+',
    ).allMatches(allText)) {
      final value = match.group(0);
      if (value != null) addCandidate(value);
    }

    for (final match in RegExp(r'\b\d{5,}\b').allMatches(allText)) {
      final value = match.group(0);
      if (value != null) addCandidate(value);
    }

    candidates.sort((a, b) {
      final rankCompare = _smartOcrCandidateRank(
        a,
      ).compareTo(_smartOcrCandidateRank(b));
      if (rankCompare != 0) return rankCompare;

      final aWords = a.split(RegExp(r'\s+')).length;
      final bWords = b.split(RegExp(r'\s+')).length;

      final aStrongCount = _tokenizeSmartOcr(
        a,
      ).where(_looksLikeStrongArticleToken).length;
      final bStrongCount = _tokenizeSmartOcr(
        b,
      ).where(_looksLikeStrongArticleToken).length;

      if (aWords != bWords) return bWords.compareTo(aWords);
      if (aStrongCount != bStrongCount) {
        return bStrongCount.compareTo(aStrongCount);
      }

      return b.length.compareTo(a.length);
    });

    debugPrint(
      'SMART OCR CANDIDATES (${candidates.length}): ${candidates.take(16).toList()}',
    );

    return candidates;
  }

  int _scoreCatalogItemForSmartOcr(CatalogItem item, String candidate) {
    final candidateNorm = _normalizeForSearch(candidate);
    final candidateCompact = _compactForSmartOcr(candidate);
    final candidateTokens = _tokenizeSmartOcr(candidate);

    if (candidateCompact.length < minSearchLen) return 0;

    final itemFields = <String>[
      item.basename,
      item.id,
      // Pfade nur als Zusatz, aber Hersteller und Typ bewusst nicht.
      item.dwgPath ?? '',
      item.dxfPath ?? '',
      item.jpgPath ?? '',
    ].where((e) => e.trim().isNotEmpty).toList();

    var bestScore = 0;

    for (final field in itemFields) {
      final fieldNorm = _normalizeForSearch(field);
      final fieldCompact = _compactForSmartOcr(field);
      final fieldTokens = _tokenizeSmartOcr(field).toSet();

      if (fieldCompact.isEmpty) continue;

      var score = 0;

      // Sehr starke Treffer.
      if (fieldNorm == candidateNorm) {
        score += 5000;
      }

      if (fieldCompact == candidateCompact) {
        score += 4500;
      }

      if (candidateCompact.length >= 5 &&
          fieldCompact.contains(candidateCompact)) {
        score += 2500 + candidateCompact.length;
      }

      if (fieldCompact.length >= 5 && candidateCompact.contains(fieldCompact)) {
        score += 1400 + fieldCompact.length;
      }

      var matchedTokens = 0;

      for (final token in candidateTokens) {
        final tokenCompact = _compactForSmartOcr(token);
        if (tokenCompact.length < 2) continue;

        final tokenInField =
            fieldTokens.contains(token) || fieldCompact.contains(tokenCompact);

        if (!tokenInField) continue;

        matchedTokens++;

        if (_looksLikeStrongArticleToken(token)) {
          score += 600;
        } else if (tokenCompact.length >= 4) {
          score += 180;
        } else {
          score += 40;
        }
      }

      // Mehrere passende Tokens sind viel besser als ein einzelner Treffer.
      // Genau dadurch gewinnt "MONO D100L" gegen nur "D100L".
      if (matchedTokens >= 2) {
        score += 1200 * matchedTokens;
      }

      // Ein einzelner kurzer Code wie D100L ist okay, aber nicht so stark wie Kombinationen.
      if (candidateTokens.length == 1 &&
          candidateCompact.length <= 5 &&
          _looksLikeStrongArticleToken(candidateTokens.first)) {
        score -= 300;
      }

      if (score > bestScore) {
        bestScore = score;
      }
    }

    return bestScore;
  }

  Future<List<OcrCatalogMatch>> _findFormattedArticleNumberOcrMatches(
    String rawText,
    List<OcrBoxCandidate> boxes,
    int ocrRunId,
  ) async {
    final formattedCandidates = <String>[];
    final formattedRegex = RegExp(r'\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+');

    void addCandidate(String value) {
      final cleaned = value.trim();
      if (cleaned.length < minSearchLen) return;
      if (!formattedRegex.hasMatch(cleaned)) return;
      if (!formattedCandidates.contains(cleaned)) {
        formattedCandidates.add(cleaned);
      }
    }

    for (final box in boxes) {
      final text = box.text.trim();
      if (formattedRegex.hasMatch(text)) {
        addCandidate(text);
      }

      for (final match in formattedRegex.allMatches(text)) {
        final value = match.group(0);
        if (value != null) addCandidate(value);
      }
    }

    for (final match in formattedRegex.allMatches(rawText)) {
      final value = match.group(0);
      if (value != null) addCandidate(value);
    }

    if (formattedCandidates.isEmpty) return [];

    debugPrint('FORMATTED OCR ARTICLE CANDIDATES: $formattedCandidates');

    final results = <OcrCatalogMatch>[];
    final seen = <String>{};

    for (final candidate in formattedCandidates.take(6)) {
      await Future<void>.delayed(Duration.zero);
      if (_isOcrRunCancelled(ocrRunId)) return [];

      final found = _fastLocalOcrSearch(candidate, limit: maxOcrResultCount);

      for (final item in found) {
        final key = '${item.id}|${item.basename}';
        if (!seen.add(key)) continue;

        results.add(
          OcrCatalogMatch(
            item: item,
            usedTerm: candidate,
            originalTerm: candidate,
            score: 12000,
          ),
        );

        if (results.length >= maxOcrResultCount) {
          debugPrint(
            'FORMATTED OCR ARTICLE MATCHES: ${results.map((e) => '${e.item.basename} | ${e.usedTerm}').toList()}',
          );
          return results;
        }
      }
    }

    if (results.isNotEmpty) {
      debugPrint(
        'FORMATTED OCR ARTICLE MATCHES: ${results.map((e) => '${e.item.basename} | ${e.usedTerm}').toList()}',
      );
    }

    return results;
  }

  Future<List<OcrCatalogMatch>> _findFrankeSinkLabelNumberOcrMatches(
    String rawText,
    List<OcrBoxCandidate> boxes,
    int ocrRunId,
  ) async {
    final candidates = <String>[];

    void addCandidates(String value) {
      for (final label in extractFrankeSinkLabelNumbers(value)) {
        if (!candidates.contains(label)) candidates.add(label);
      }
    }

    for (final box in boxes) {
      addCandidates(box.text);
    }
    addCandidates(rawText);

    if (candidates.isEmpty) return [];

    debugPrint('FRANKE SINK LABEL OCR CANDIDATES: $candidates');

    final results = <OcrCatalogMatch>[];
    final seen = <String>{};

    for (final candidate in candidates.take(6)) {
      await Future<void>.delayed(Duration.zero);
      if (_isOcrRunCancelled(ocrRunId)) return [];

      final found = _fastLocalOcrSearch(candidate, limit: maxOcrResultCount);

      for (final item in found) {
        final key = '${item.id}|${item.basename}';
        if (!seen.add(key)) continue;

        results.add(
          OcrCatalogMatch(
            item: item,
            usedTerm: candidate,
            originalTerm: candidate,
            score: 14000,
          ),
        );

        if (results.length >= maxOcrResultCount) {
          debugPrint(
            'FRANKE SINK LABEL OCR MATCHES: ${results.map((e) => '${e.item.basename} | ${e.usedTerm}').toList()}',
          );
          return results;
        }
      }
    }

    if (results.isNotEmpty) {
      debugPrint(
        'FRANKE SINK LABEL OCR MATCHES: ${results.map((e) => '${e.item.basename} | ${e.usedTerm}').toList()}',
      );
    }

    return results;
  }

  Future<List<OcrCatalogMatch>> _findBlancoSinkLabelNumberOcrMatches(
    String rawText,
    List<OcrBoxCandidate> boxes,
    int ocrRunId,
  ) async {
    final candidates = rankBlancoSinkLabelNumbers(
      rawText: rawText,
      boxes: boxes
          .map(
            (box) => OcrLabelBoxText(
              text: box.text,
              area: box.area,
              height: box.height,
            ),
          )
          .toList(),
    );

    if (candidates.isEmpty) return [];

    debugPrint('BLANCO SINK LABEL OCR CANDIDATES: $candidates');

    final results = <OcrCatalogMatch>[];
    final seen = <String>{};

    for (final candidate in candidates.take(6)) {
      await Future<void>.delayed(Duration.zero);
      if (_isOcrRunCancelled(ocrRunId)) return [];

      final found = _fastLocalOcrSearch(candidate, limit: maxOcrResultCount);

      for (final item in found) {
        final key = '${item.id}|${item.basename}';
        if (!seen.add(key)) continue;

        results.add(
          OcrCatalogMatch(
            item: item,
            usedTerm: candidate,
            originalTerm: candidate,
            score: 13500,
          ),
        );

        if (results.length >= maxOcrResultCount) {
          debugPrint(
            'BLANCO SINK LABEL OCR MATCHES: ${results.map((e) => '${e.item.basename} | ${e.usedTerm}').toList()}',
          );
          return results;
        }
      }
    }

    if (results.isNotEmpty) {
      debugPrint(
        'BLANCO SINK LABEL OCR MATCHES: ${results.map((e) => '${e.item.basename} | ${e.usedTerm}').toList()}',
      );
    }

    return results;
  }

  Future<List<OcrCatalogMatch>> _findBoraModelNumberOcrMatches(
    String rawText,
    List<OcrBoxCandidate> boxes,
    int ocrRunId,
  ) async {
    final candidates = rankBoraModelNumbers(
      rawText: rawText,
      boxes: boxes
          .map(
            (box) => OcrLabelBoxText(
              text: box.text,
              area: box.area,
              height: box.height,
            ),
          )
          .toList(),
    );

    if (candidates.isEmpty) return [];

    debugPrint('BORA MODEL OCR CANDIDATES: $candidates');

    final results = <OcrCatalogMatch>[];
    final seen = <String>{};

    for (final candidate in candidates.take(6)) {
      await Future<void>.delayed(Duration.zero);
      if (_isOcrRunCancelled(ocrRunId)) return [];

      final found = _fastLocalOcrSearch(candidate, limit: maxOcrResultCount);

      for (final item in found) {
        final key = '${item.id}|${item.basename}';
        if (!seen.add(key)) continue;

        results.add(
          OcrCatalogMatch(
            item: item,
            usedTerm: candidate,
            originalTerm: candidate,
            score: 13200,
          ),
        );

        if (results.length >= maxOcrResultCount) {
          debugPrint(
            'BORA MODEL OCR MATCHES: ${results.map((e) => '${e.item.basename} | ${e.usedTerm}').toList()}',
          );
          return results;
        }
      }
    }

    if (results.isNotEmpty) {
      debugPrint(
        'BORA MODEL OCR MATCHES: ${results.map((e) => '${e.item.basename} | ${e.usedTerm}').toList()}',
      );
    }

    return results;
  }

  Future<List<OcrCatalogMatch>> _findFastNumberOcrMatches(
    String rawText,
    List<OcrBoxCandidate> boxes,
    int ocrRunId,
  ) async {
    final numberCandidates = <String>[];

    void addNumber(String value) {
      final cleaned = value.trim();

      if (cleaned.length < minSearchLen) return;

      final digitsOnly = cleaned.replaceAll(RegExp(r'[^0-9]'), '');

      if (digitsOnly.length >= 9 && RegExp(r'^\d+$').hasMatch(cleaned)) {
        return;
      }

      // Nur iOS:
      // Lange reine Barcode-/Seriennummern komplett ignorieren.
      // Beispiel: 00235469970000000911
      if (_isIosOcrMode &&
          digitsOnly.length >= 11 &&
          RegExp(r'^[0-9\s.\-/]+$').hasMatch(cleaned)) {
        debugPrint('iOS OCR BARCODE SKIPPED: $cleaned');
        return;
      }

      void addUnique(String candidate) {
        final c = candidate.trim();
        if (c.length < minSearchLen) return;

        if (!numberCandidates.contains(c)) {
          numberCandidates.add(c);
        }
      }

      addUnique(cleaned);

      final compact = cleaned.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');

      if (compact.length >= minSearchLen) {
        addUnique(compact);

        if (compact.startsWith('0')) {
          final stripped = compact.replaceFirst(RegExp(r'^0+'), '');
          addUnique(stripped);
        }
      }
    }

    // 1. Reine Zahlen und formatierte Artikelnummern aus OCR-Boxen bevorzugen.
    // Beispiele:
    // 521841
    // 127.0658.064
    // 8250573-1
    for (final box in boxes) {
      final text = box.text.trim();

      if (RegExp(r'^\d{4,}$').hasMatch(text)) {
        addNumber(text);
      }

      if (RegExp(r'^\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+$').hasMatch(text)) {
        addNumber(text);
      }
    }

    // 2. Danach Zahlen aus dem gesamten OCR-Text ziehen
    final combinedText = [rawText, ...boxes.map((e) => e.text)].join(' ');

    for (final match in RegExp(r'\b\d{4,}\b').allMatches(combinedText)) {
      final value = match.group(0);
      final before = _normalizeForSearch(
        combinedText.substring(
          match.start >= 12 ? match.start - 12 : 0,
          match.start,
        ),
      );
      if (value != null) {
        if (value.length == 5 && RegExp(r'\bde\s*$').hasMatch(before)) {
          continue;
        }
        if (RegExp(r'\b(en|ce|ukca|dop|pwd)\s*$').hasMatch(before)) {
          continue;
        }
        addNumber(value);
      }
    }

    for (final match in RegExp(
      r'\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+',
    ).allMatches(combinedText)) {
      final value = match.group(0);
      if (value != null) {
        addNumber(value);
      }
    }

    if (_isIosOcrMode) {
      numberCandidates.sort((a, b) {
        final priorityCompare = _ocrCandidatePriority(
          a,
        ).compareTo(_ocrCandidatePriority(b));

        if (priorityCompare != 0) {
          return priorityCompare;
        }

        return a.length.compareTo(b.length);
      });
    }

    debugPrint('FAST OCR NUMBER CANDIDATES: $numberCandidates');

    final results = <OcrCatalogMatch>[];
    final seen = <String>{};

    final numberLimit = _isIosOcrMode ? 20 : 12;
    final searchLimit = _isIosOcrMode ? 5 : 3;

    for (final number in numberCandidates.take(numberLimit)) {
      await Future<void>.delayed(Duration.zero);
      if (_isOcrRunCancelled(ocrRunId)) return [];

      final found = _fastLocalOcrSearch(number, limit: searchLimit);

      for (final item in found) {
        final key = '${item.id}|${item.basename}';
        if (seen.contains(key)) continue;

        seen.add(key);

        results.add(
          OcrCatalogMatch(
            item: item,
            usedTerm: number,
            originalTerm: number,
            score: 9999,
          ),
        );

        if (results.length >= maxOcrResultCount) {
          debugPrint(
            'FAST OCR NUMBER MATCHES: ${results.map((e) => '${e.item.basename} | ${e.usedTerm}').toList()}',
          );
          return results;
        }
      }
    }

    return results;
  }

  bool _isLikelyBarcodeNumber(String value) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');

    // Sehr lange reine Zahlen sind oft Barcode-, Serien- oder Versandnummern.
    if (digits.length >= 11 && RegExp(r'^[0-9\s.\-/]+$').hasMatch(value)) {
      return true;
    }

    return false;
  }

  int _ocrCandidatePriority(String value) {
    final normalized = _normalizeOcrSearchTerm(value);
    final compact = normalized.replaceAll(RegExp(r'[^a-z0-9]'), '');

    final hasLetter = RegExp(r'[a-z]').hasMatch(compact);
    final hasDigit = RegExp(r'\d').hasMatch(compact);
    final digitsOnly = compact.replaceAll(RegExp(r'[^0-9]'), '');

    // Modellnummern wie EH601HFB1E, KMDA7473, D100L bevorzugen.
    if (hasLetter && hasDigit && compact.length >= 5) {
      return 0;
    }

    // Formatierte Artikelnummern wie 127.0658.064 bevorzugen.
    if (RegExp(
      r'\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+',
    ).hasMatch(normalized)) {
      return 1;
    }

    // Kurze/mittlere Materialnummern wie 00235469, 521841 bevorzugen.
    if (digitsOnly.length >= minSearchLen && digitsOnly.length <= 10) {
      return 2;
    }

    // Normale Texte danach.
    if (!_isLikelyBarcodeNumber(normalized)) {
      return 3;
    }

    // Lange Barcode-Zahlen ganz nach hinten.
    return 9;
  }

  Future<List<OcrCatalogMatch>> _findBestSmartOcrCatalogMatches(
    String rawText,
    List<OcrBoxCandidate> boxes, {
    required int ocrRunId,
    List<String>? prebuiltCandidates,
  }) async {
    final candidates =
        prebuiltCandidates ?? _buildSmartOcrCandidates(rawText, boxes);

    final scoredMatches = <OcrCatalogMatch>[];
    final seenItems = <String>{};

    // Wichtig für Geschwindigkeit:
    // Nicht mehr 80 Kandidaten prüfen, sondern nur die besten 15.
    final candidateLimit = _isIosOcrMode ? 20 : 16;

    for (final candidate in candidates.take(candidateLimit)) {
      await Future<void>.delayed(Duration.zero);
      if (_isOcrRunCancelled(ocrRunId)) return [];

      final prefilterLimit = _isIosOcrMode ? 15 : 8;
      final prefilteredItems = _fastLocalOcrSearch(
        candidate,
        limit: prefilterLimit,
      );

      if (prefilteredItems.isEmpty) {
        continue;
      }

      for (final item in prefilteredItems) {
        final itemKey = '${item.id}|${item.basename}';

        final score = _scoreCatalogItemForSmartOcr(item, candidate);

        if (score < 1800) {
          continue;
        }

        scoredMatches.add(
          OcrCatalogMatch(
            item: item,
            usedTerm: candidate,
            originalTerm: candidate,
            score: score,
          ),
        );

        seenItems.add(itemKey);
      }
    }

    scoredMatches.sort((a, b) => b.score.compareTo(a.score));

    final uniqueMatches = <OcrCatalogMatch>[];
    final uniqueKeys = <String>{};

    for (final match in scoredMatches) {
      final key = '${match.item.id}|${match.item.basename}';

      if (uniqueKeys.contains(key)) {
        continue;
      }

      uniqueKeys.add(key);
      uniqueMatches.add(match);

      if (uniqueMatches.length >= maxOcrResultCount) {
        break;
      }
    }

    if (uniqueMatches.isEmpty) {
      debugPrint('SMART OCR BEST MATCHES: none');
      return [];
    }

    debugPrint(
      'SMART OCR BEST MATCHES: ${uniqueMatches.map((e) => '${e.item.basename} | term="${e.usedTerm}" | score=${e.score}').toList()}',
    );

    return uniqueMatches;
  }

  List<OcrCatalogMatch> _limitUniqueOcrMatches(List<OcrCatalogMatch> matches) {
    final result = <OcrCatalogMatch>[];
    final seen = <String>{};

    for (final match in matches) {
      final key = '${match.item.id}|${match.item.basename}';
      if (seen.contains(key)) continue;

      seen.add(key);
      result.add(match);

      if (result.length >= maxOcrResultCount) break;
    }

    return result;
  }

  List<List<OcrBoxCandidate>> _buildOcrBoxSearchStages(
    List<OcrBoxCandidate> boxes,
  ) {
    if (boxes.isEmpty) return [];

    final stages = <List<OcrBoxCandidate>>[];
    final signatures = <String>{};
    final maxHeight = boxes.first.height;

    void addStage(Iterable<OcrBoxCandidate> source) {
      final stage = source.where((e) => e.text.trim().isNotEmpty).toList();
      if (stage.isEmpty) return;

      final signature = stage.map((e) => e.text).join('|');
      if (signatures.contains(signature)) return;

      signatures.add(signature);
      stages.add(stage);
    }

    addStage(boxes.where((box) => box.height >= maxHeight * 0.82).take(4));
    addStage(boxes.take(4));
    addStage(boxes.take(8));
    addStage(boxes.take(12));
    addStage(boxes.take(20));

    return stages;
  }

  bool _isOcrRunCancelled(int ocrRunId) {
    return _ocrCancelRequested || ocrRunId != _ocrRunId;
  }

  Future<void> _deleteOcrTempFiles(Iterable<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Temporäre OCR-Dateien sind nur ein Cache und dürfen den Ablauf nicht
        // beeinflussen.
      }
    }
  }

  Future<List<OcrCatalogMatch>> _findStructuredOcrCatalogMatches(
    String rawText,
    List<OcrBoxCandidate> sortedBoxes,
    int ocrRunId,
  ) {
    return _findStructuredOcrCatalogMatchesAsync(
      rawText,
      sortedBoxes,
      ocrRunId,
    );
  }

  Future<List<OcrCatalogMatch>> _findStructuredOcrCatalogMatchesAsync(
    String rawText,
    List<OcrBoxCandidate> sortedBoxes,
    int ocrRunId,
  ) async {
    final stages = _buildOcrBoxSearchStages(sortedBoxes);
    final searchedSmartSignatures = <String>{};

    final blancoSinkLabelMatches = await _findBlancoSinkLabelNumberOcrMatches(
      rawText,
      sortedBoxes,
      ocrRunId,
    );
    if (blancoSinkLabelMatches.isNotEmpty) {
      return _limitUniqueOcrMatches(blancoSinkLabelMatches);
    }
    if (_hasBlancoSinkLabelNumber(rawText, sortedBoxes)) {
      return [];
    }

    final frankeSinkLabelMatches = await _findFrankeSinkLabelNumberOcrMatches(
      rawText,
      sortedBoxes,
      ocrRunId,
    );
    if (frankeSinkLabelMatches.isNotEmpty) {
      return _limitUniqueOcrMatches(frankeSinkLabelMatches);
    }
    if (_hasFrankeSinkLabelNumber(rawText, sortedBoxes)) {
      return [];
    }

    final boraModelMatches = await _findBoraModelNumberOcrMatches(
      rawText,
      sortedBoxes,
      ocrRunId,
    );
    if (boraModelMatches.isNotEmpty) {
      return _limitUniqueOcrMatches(boraModelMatches);
    }
    if (_hasBoraModelNumber(rawText, sortedBoxes)) {
      return [];
    }

    final formattedArticleMatches = await _findFormattedArticleNumberOcrMatches(
      rawText,
      sortedBoxes,
      ocrRunId,
    );
    if (formattedArticleMatches.isNotEmpty) {
      return _limitUniqueOcrMatches(formattedArticleMatches);
    }

    for (int i = 0; i < stages.length; i++) {
      await Future<void>.delayed(Duration.zero);
      if (_isOcrRunCancelled(ocrRunId)) return [];

      final stage = stages[i];
      debugPrint(
        'OCR SEARCH STAGE ${i + 1}/${stages.length}: ${stage.map((e) => '${e.text} (${e.height.toStringAsFixed(0)})').toList()}',
      );

      final smartCandidates = _buildSmartOcrCandidates('', stage);
      final smartSignature = smartCandidates.take(16).join('|');
      if (smartSignature.isNotEmpty &&
          searchedSmartSignatures.add(smartSignature)) {
        final smartMatches = await _findBestSmartOcrCatalogMatches(
          '',
          stage,
          ocrRunId: ocrRunId,
          prebuiltCandidates: smartCandidates,
        );
        if (smartMatches.isNotEmpty) {
          return _limitUniqueOcrMatches(smartMatches);
        }
      }

      await Future<void>.delayed(Duration.zero);
      if (_isOcrRunCancelled(ocrRunId)) return [];

      final fastMatches = await _findFastNumberOcrMatches('', stage, ocrRunId);
      if (fastMatches.isNotEmpty) {
        return _limitUniqueOcrMatches(fastMatches);
      }
    }

    await Future<void>.delayed(Duration.zero);
    if (_isOcrRunCancelled(ocrRunId)) return [];

    final fullSmartCandidates = _buildSmartOcrCandidates(rawText, sortedBoxes);
    final fullSmartSignature = fullSmartCandidates.take(16).join('|');
    if (fullSmartSignature.isNotEmpty &&
        !searchedSmartSignatures.add(fullSmartSignature)) {
      final fullFastMatches = await _findFastNumberOcrMatches(
        rawText,
        sortedBoxes,
        ocrRunId,
      );
      return _limitUniqueOcrMatches(fullFastMatches);
    }

    final fullSmartMatches = await _findBestSmartOcrCatalogMatches(
      rawText,
      sortedBoxes,
      ocrRunId: ocrRunId,
      prebuiltCandidates: fullSmartCandidates,
    );

    if (fullSmartMatches.isNotEmpty) {
      return _limitUniqueOcrMatches(fullSmartMatches);
    }

    await Future<void>.delayed(Duration.zero);
    if (_isOcrRunCancelled(ocrRunId)) return [];

    final fullFastMatches = await _findFastNumberOcrMatches(
      rawText,
      sortedBoxes,
      ocrRunId,
    );
    return _limitUniqueOcrMatches(fullFastMatches);
  }

  Future<void> _runLocalOcr(ImageSource source) async {
    int? startedOcrRunId;

    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: source,
        imageQuality: _isIosOcrMode ? 100 : 90,
        maxWidth: 1800,
        maxHeight: 1800,
      );

      if (picked == null) return;
      if (!mounted) return;

      final currentOcrRunId = ++_ocrRunId;
      startedOcrRunId = currentOcrRunId;

      setState(() {
        _searchLoading = true;
        _message = '';
        _ocrBoxTexts = [];
        _results = [];
        _showOcrSuggestions = false;
        _activeHighlightTerm = '';
        _showSinkLabelMatchWarning = false;
        _recognizedSinkLabelNumber = '';
        _resultChromeCollapsed = false;
        _ocrSearchActive = true;
        _ocrCancelRequested = false;
      });

      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted || _ocrCancelRequested || currentOcrRunId != _ocrRunId) {
        return;
      }

      final preparedImage = await _prepareOcrInputImage(picked.path);
      final tempOcrPaths = <String>{
        if (preparedImage.isTemporary) preparedImage.path,
      };
      if (_isOcrRunCancelled(currentOcrRunId)) {
        await _deleteOcrTempFiles(tempOcrPaths);
        return;
      }
      final imageVariants = <({String path, int rotation})>[
        (path: preparedImage.path, rotation: 0),
      ];
      var fallbackRotationsLoaded = false;

      List<CatalogItem> bestMatches = [];
      String bestUsedSearchText = '';
      int bestSmartOcrScore = 0;
      List<String> bestVisibleBoxTexts = [];
      String bestRawText = '';
      int bestRotation = 0;

      for (int i = 0; i < imageVariants.length; i++) {
        final variant = imageVariants[i];
        final inputImage = InputImage.fromFilePath(variant.path);
        final textRecognizer = TextRecognizer(
          script: TextRecognitionScript.latin,
        );

        RecognizedText recognizedText;

        try {
          recognizedText = await textRecognizer.processImage(inputImage);
        } finally {
          await textRecognizer.close();
        }

        final sortedBoxes = _extractOcrBoxCandidatesSorted(recognizedText);
        final rawText = recognizedText.text.trim();
        final preferredArticle = _extractPreferredArticleNumber(rawText);
        final visibleBoxTexts = sortedBoxes
            .map((e) => e.text)
            .take(12)
            .toList();

        if (mounted &&
            currentOcrRunId == _ocrRunId &&
            visibleBoxTexts.isNotEmpty &&
            !_ocrCancelRequested) {
          setState(() {
            _ocrBoxTexts = visibleBoxTexts;
            _showOcrSuggestions = true;
            _message = tr(
              'OCR liest den Aufkleber. Du kannst unten schon einen Begriff antippen oder abbrechen.',
              'OCR is reading the label. You can already select a term below or cancel.',
            );
          });
        }

        if (_ocrCancelRequested || currentOcrRunId != _ocrRunId) {
          break;
        }

        debugPrint('OCR VARIANT ROTATION: ${variant.rotation}');
        debugPrint('OCR RAW TEXT: $rawText');
        debugPrint('OCR PREFERRED ARTICLE: $preferredArticle');
        debugPrint(
          'OCR BOXES SORTED: ${sortedBoxes.map((e) => '${e.text} (${e.area.toStringAsFixed(0)})').toList()}',
        );

        List<CatalogItem> matches = [];
        String usedSearchText = '';
        int smartOcrScore = 0;

        final structuredMatches = await _findStructuredOcrCatalogMatches(
          rawText,
          sortedBoxes,
          currentOcrRunId,
        );

        if (_ocrCancelRequested || currentOcrRunId != _ocrRunId) {
          break;
        }

        if (structuredMatches.isNotEmpty) {
          matches = structuredMatches.map((e) => e.item).toList();
          usedSearchText = structuredMatches.first.usedTerm;
          smartOcrScore = structuredMatches.first.score;
        }

        // Sehr eindeutiger Fallback, falls Preferred-Article-Erkennung
        // eine konkrete Nummer erkennt.
        if (matches.isEmpty &&
            preferredArticle != null &&
            preferredArticle.isNotEmpty &&
            !(_isIosOcrMode && _isLikelyBarcodeNumber(preferredArticle))) {
          final found = _localOcrSearch(preferredArticle);

          if (found.isNotEmpty) {
            matches = found.take(maxOcrResultCount).toList();
            usedSearchText = preferredArticle;
            smartOcrScore = 9999;
          }
        }

        // Falls noch kein Treffer da ist, trotzdem brauchbare OCR-Vorschläge merken.
        if (bestVisibleBoxTexts.isEmpty && visibleBoxTexts.isNotEmpty) {
          bestVisibleBoxTexts = visibleBoxTexts;
          bestRawText = rawText;
          bestRotation = variant.rotation;
        }

        if (matches.isNotEmpty && smartOcrScore > bestSmartOcrScore) {
          bestMatches = matches;
          bestUsedSearchText = usedSearchText;
          bestSmartOcrScore = smartOcrScore;
          bestVisibleBoxTexts = visibleBoxTexts;
          bestRawText = rawText;
          bestRotation = variant.rotation;
        }

        // Wenn ein Treffer gefunden wurde, sparen wir uns die teuren Rotationen.
        if (bestMatches.isNotEmpty) {
          break;
        }

        if (_ocrCancelRequested || currentOcrRunId != _ocrRunId) {
          break;
        }

        if (i == imageVariants.length - 1 && !fallbackRotationsLoaded) {
          final fallbackVariants = await _buildFallbackOcrImageVariants(
            preparedImage.path,
          );
          tempOcrPaths.addAll(fallbackVariants.map((e) => e.path));
          if (_isOcrRunCancelled(currentOcrRunId)) {
            break;
          }
          imageVariants.addAll(fallbackVariants);
          fallbackRotationsLoaded = true;
        }
      }

      // Temporaere OCR-Zwischenbilder loeschen.
      await _deleteOcrTempFiles(tempOcrPaths);

      if (!mounted) return;

      if (currentOcrRunId != _ocrRunId) {
        return;
      }

      if (_ocrCancelRequested) {
        setState(() {
          _searchLoading = false;
          _ocrSearchActive = false;
          _results = [];
          _showSinkLabelMatchWarning = false;
          _recognizedSinkLabelNumber = '';
          _resultChromeCollapsed = false;
          _showOcrSuggestions = _ocrBoxTexts.isNotEmpty;
          _message = tr(
            'OCR-Suche abgebrochen. Wähle einen erkannten Begriff aus der Liste.',
            'OCR search canceled. Select a recognized term from the list.',
          );
        });
        return;
      }

      debugPrint('SMART OCR BEST ROTATION: $bestRotation');
      debugPrint('SMART OCR BEST RAW TEXT: $bestRawText');
      debugPrint('SMART OCR FINAL SCORE: $bestSmartOcrScore');

      if (bestMatches.isEmpty) {
        final recognizedLabel =
            recognizedSinkLabelNumber(
              [bestRawText, ...bestVisibleBoxTexts].join(' '),
            ) ??
            '';
        _logSearchQuality(
          event: 'search',
          searchType: 'ocr',
          term: recognizedLabel.isNotEmpty ? recognizedLabel : bestRawText,
          usedTerm: recognizedLabel,
          labelRule: _labelRuleNameForSearchTerm(recognizedLabel),
          recognizedLabel: recognizedLabel,
          resultCount: 0,
          ocrTerms: bestVisibleBoxTexts,
        );

        setState(() {
          _searchLoading = false;
          _ocrSearchActive = false;
          _results = [];
          _showSinkLabelMatchWarning = false;
          _recognizedSinkLabelNumber = '';
          _resultChromeCollapsed = false;
          _ocrBoxTexts = bestVisibleBoxTexts;
          _showOcrSuggestions = true;
          _message = _isIosOcrMode
              ? tr(
                  'Keine hinterlegten Artikel im Aufkleber gefunden. Tipp: Etikett gerade und möglichst bildfüllend fotografieren.',
                  'No stored items were found on the label. Tip: Photograph the label straight and as full-frame as possible.',
                )
              : tr(
                  'Keine hinterlegten Artikel im Aufkleber gefunden.',
                  'No stored items were found on the label.',
                );
        });
        return;
      }

      setState(() {
        _searchLoading = false;
        _ocrSearchActive = false;
        _results = bestMatches;
        _resultChromeCollapsed = true;
        _ocrBoxTexts = bestVisibleBoxTexts;
        _showOcrSuggestions = bestVisibleBoxTexts.isNotEmpty;
        _activeHighlightTerm = bestUsedSearchText;
        _showSinkLabelMatchWarning =
            bestMatches.isNotEmpty &&
            _isSinkLabelSearchTerm(bestUsedSearchText);
        _recognizedSinkLabelNumber = _showSinkLabelMatchWarning
            ? _recognizedSinkLabelNumberForSearchTerm(bestUsedSearchText)
            : '';

        if (bestUsedSearchText.isNotEmpty) {
          final rotationInfo = _isIosOcrMode && bestRotation != 0
              ? isEnglish
                    ? ' Image rotation: $bestRotation°.'
                    : ' Bilddrehung: $bestRotation°.'
              : '';

          _message = isEnglish
              ? 'ATool match from smart search: $bestUsedSearchText – showing the best ${bestMatches.length} results.$rotationInfo'
              : 'ATool-Treffer über intelligente Suche: $bestUsedSearchText – beste ${bestMatches.length} Treffer angezeigt.$rotationInfo';
        } else {
          _message = '';
        }
      });

      if (bestUsedSearchText.isNotEmpty) {
        _setSearchTextSilently(bestUsedSearchText);
      }

      final labelRule = _labelRuleNameForSearchTerm(bestUsedSearchText);
      _logSearchQuality(
        event: 'search',
        searchType: 'ocr',
        term: bestUsedSearchText,
        usedTerm: bestUsedSearchText,
        labelRule: labelRule,
        recognizedLabel: labelRule.isNotEmpty
            ? _recognizedSinkLabelNumberForSearchTerm(bestUsedSearchText)
            : '',
        resultCount: bestMatches.length,
        results: bestMatches,
        ocrTerms: bestVisibleBoxTexts,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isEnglish
                ? '${bestMatches.length} items found on the label.'
                : '${bestMatches.length} Artikel aus dem Aufkleber gefunden.',
          ),
        ),
      );
    } catch (e, stackTrace) {
      debugPrint('OCR ERROR: $e');
      debugPrint('$stackTrace');

      if (!mounted) return;
      if (startedOcrRunId != null && startedOcrRunId != _ocrRunId) return;

      setState(() {
        _searchLoading = false;
        _ocrSearchActive = false;
        _showSinkLabelMatchWarning = false;
        _recognizedSinkLabelNumber = '';
        _resultChromeCollapsed = false;
        _message = tr('Kamera/OCR fehlgeschlagen.', 'Camera/OCR failed.');
      });
    }
  }

  Future<void> _loadDwgDisplayCount() async {
    final cachedCount = await CatalogCachePrefs.getDwgDisplayCount();
    if (cachedCount != null && mounted) {
      setState(() {
        _dwgDisplayCount = cachedCount;
        _countLoading = false;
      });
    }

    try {
      final resp = await http
          .get(Uri.parse(AppConfig.dwgListUrl))
          .timeout(const Duration(seconds: 8));
      final count = await compute(_parseDwgDisplayCountInBackground, resp.body);

      if (count != null) {
        await CatalogCachePrefs.setDwgDisplayCount(count);

        if (!mounted) return;

        setState(() {
          _dwgDisplayCount = count;
          _countLoading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _countLoading = false;
      });
    }
  }

  Future<void> _handleSearchDirect(
    String term, {
    bool preserveOcrSuggestions = false,
  }) async {
    final q = term.trim();
    if (q.length < manualSearchLen) return;
    final runId = ++_manualSearchRunId;

    if (_catalog.isEmpty) {
      setState(() {
        _results = [];
        _searchLoading = false;
        _activeHighlightTerm = q;
        _showSinkLabelMatchWarning = false;
        _recognizedSinkLabelNumber = '';
        _resultChromeCollapsed = false;
        _message = tr(
          'Katalog wird noch geladen. Bitte kurz erneut suchen.',
          'The catalog is still loading. Please try again shortly.',
        );
      });
      return;
    }

    if (_catalogSearchIndex.isEmpty) {
      setState(() {
        _results = [];
        _searchLoading = false;
        _activeHighlightTerm = q;
        _showSinkLabelMatchWarning = false;
        _recognizedSinkLabelNumber = '';
        _resultChromeCollapsed = false;
        _message = tr(
          'Katalog wird vorbereitet. Bitte kurz erneut suchen.',
          'The catalog is being prepared. Please try again shortly.',
        );
      });
      _scheduleCatalogSearchIndexRebuild();
      return;
    }

    setState(() {
      _ocrRunId++;
      _searchLoading = false;
      _message = '';
      _showSinkLabelMatchWarning = false;
      _recognizedSinkLabelNumber = '';
      _resultChromeCollapsed = false;
      if (!preserveOcrSuggestions) {
        _showOcrSuggestions = false;
        _ocrBoxTexts = [];
      }
      _activeHighlightTerm = q;
      _ocrSearchActive = false;
      _ocrCancelRequested = true;
    });

    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;

    try {
      List<CatalogItem> found = [];
      String usedSearchTerm = q;

      final fallbackTerms = _buildSearchFallbackTerms(q);

      for (final searchTerm in fallbackTerms) {
        final currentFound = _localSearch(searchTerm);

        if (currentFound.isNotEmpty) {
          found = currentFound;
          usedSearchTerm = searchTerm;
          break;
        }
      }

      if (!mounted) return;
      if (runId != _manualSearchRunId) return;

      setState(() {
        _results = found;
        _searchLoading = false;
        _resultChromeCollapsed = found.isNotEmpty && !_searchFocusNode.hasFocus;
        _activeHighlightTerm = usedSearchTerm;
        _showSinkLabelMatchWarning =
            found.isNotEmpty && _isSinkLabelSearchTerm(usedSearchTerm);
        _recognizedSinkLabelNumber = _showSinkLabelMatchWarning
            ? _recognizedSinkLabelNumberForSearchTerm(usedSearchTerm)
            : '';

        if (found.isNotEmpty && usedSearchTerm != q) {
          _message = isEnglish
              ? 'No exact match for “$q”. Showing results for “$usedSearchTerm”.'
              : 'Kein exakter Treffer für "$q". Treffer für "$usedSearchTerm" angezeigt.';
        } else {
          _message = '';
        }
      });

      _logSearchQuality(
        event: 'search',
        searchType: 'manual',
        term: q,
        usedTerm: usedSearchTerm,
        labelRule: _labelRuleNameForSearchTerm(usedSearchTerm),
        recognizedLabel:
            found.isNotEmpty && _isSinkLabelSearchTerm(usedSearchTerm)
            ? _recognizedSinkLabelNumberForSearchTerm(usedSearchTerm)
            : '',
        resultCount: found.length,
        results: found,
      );
    } catch (_) {
      if (!mounted) return;
      if (runId != _manualSearchRunId) return;
      setState(() {
        _searchLoading = false;
        _showSinkLabelMatchWarning = false;
        _recognizedSinkLabelNumber = '';
        _resultChromeCollapsed = false;
        _message = tr('Suche fehlgeschlagen.', 'Search failed.');
      });
    }
  }

  Future<void> _showInfoDialog() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const InfoLicensePage()));
    if (mounted) setState(() {});
  }

  void _cancelOcrSearch() {
    if (!_ocrSearchActive) return;

    setState(() {
      _ocrRunId++;
      _ocrCancelRequested = true;
      _ocrSearchActive = false;
      _searchLoading = false;
      _showOcrSuggestions = _ocrBoxTexts.isNotEmpty;
      _message = _ocrBoxTexts.isNotEmpty
          ? tr(
              'OCR-Suche abgebrochen. Wähle einen erkannten Begriff aus der Liste.',
              'OCR search canceled. Select a recognized term from the list.',
            )
          : tr(
              'OCR-Suche abgebrochen. Gib die Artikelnummer manuell ein.',
              'OCR search canceled. Enter the item number manually.',
            );
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusNode.canRequestFocus = true;
      _searchFocusNode.requestFocus();
      _searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchController.text.length,
      );
    });
  }

  Future<void> _applyOcrSuggestion(String term) async {
    final q = term.trim();
    if (q.isEmpty) return;

    _ocrCancelRequested = true;
    _ocrRunId++;
    _setSearchTextSilently(q);

    if (mounted) {
      setState(() {
        _ocrSearchActive = false;
        _searchLoading = false;
        _activeHighlightTerm = q;
        _message = '';
      });
    }

    await Future<void>.delayed(const Duration(milliseconds: 80));

    await _handleSearchDirect(q, preserveOcrSuggestions: true);
  }

  Future<void> _openImageViewer(String imageUrl, String filename) async {
    if (!mounted) return;
    final localImagePath = await OfflineImageStore.existingPathForUrl(imageUrl);
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewerPage(
          imageUrl: imageUrl,
          filename: filename,
          localImagePath: localImagePath,
        ),
      ),
    );
  }

  Future<({String value, String label})?> _pickDownloadDirectory() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final result = await _downloadChannel.invokeMapMethod<String, dynamic>(
          'pickDownloadDirectory',
        );

        final uri = result?['uri']?.toString() ?? '';
        final name = result?['name']?.toString() ?? '';

        if (uri.isEmpty) return null;

        return (
          value: uri,
          label: name.isNotEmpty
              ? name
              : tr('Ausgewählter Ordner', 'Selected folder'),
        );
      }

      if (!kIsWeb && Platform.isIOS) {
        final result = await _downloadChannel.invokeMapMethod<String, dynamic>(
          'pickDownloadDirectory',
        );

        final bookmark = result?['bookmark']?.toString() ?? '';
        final name = result?['name']?.toString() ?? '';

        if (bookmark.isEmpty) return null;

        return (
          value: bookmark,
          label: name.isNotEmpty
              ? name
              : tr('Ausgewählter Ordner', 'Selected folder'),
        );
      }

      final String? dir = await FilePicker.getDirectoryPath(
        dialogTitle: tr('Download-Ordner wählen', 'Select download folder'),
      );
      if (dir == null || dir.isEmpty) return null;
      return (value: dir, label: dir);
    } catch (_) {
      return null;
    }
  }

  // ignore: unused_element
  Future<bool> _askUseSavedDirectoryLegacy(String dirLabel) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr('Download-Ziel', 'Download destination')),
        content: Text(
          isEnglish
              ? 'Use the saved folder?\n\n$dirLabel'
              : 'Gespeicherten Ordner verwenden?\n\n$dirLabel',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(tr('Neuen Ordner wählen', 'Select new folder')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(tr('Verwenden', 'Use')),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  Future<bool?> _askUseSavedDirectory(String dirLabel) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2C),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.folder_outlined,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tr('Download-Ziel', 'Download destination'),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Abbrechen', 'Cancel'),
                    onPressed: () => Navigator.of(dialogContext).pop(null),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                tr('Gespeicherten Ordner verwenden?', 'Use the saved folder?'),
                style: const TextStyle(
                  color: Color(0xFF555555),
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F4F4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.folder_open_outlined,
                      color: Color(0xFF444444),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        dirLabel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _downloadActionTile(
                dialogContext: dialogContext,
                icon: Icons.check_circle_outline,
                title: tr('Verwenden', 'Use'),
                subtitle: tr(
                  'Datei in diesem Ordner speichern',
                  'Save the file in this folder',
                ),
                value: true,
                primary: true,
              ),
              const SizedBox(height: 10),
              _downloadActionTile(
                dialogContext: dialogContext,
                icon: Icons.create_new_folder_outlined,
                title: tr('Neuen Ordner wählen', 'Select new folder'),
                subtitle: tr(
                  'Ein anderes Speicherziel auswählen',
                  'Select a different destination',
                ),
                value: false,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(null),
                  child: Text(tr('Abbrechen', 'Cancel')),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return result;
  }

  Future<void> _saveBytesToDirectory({
    required Uint8List bytes,
    required String directoryPath,
    required String fileName,
  }) async {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      await _downloadChannel.invokeMethod<void>('saveFileToDirectory', {
        'directoryUri': directoryPath,
        'fileName': fileName,
        'bytes': bytes,
      });
      return;
    }

    final file = File('$directoryPath${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
  }

  Widget _downloadActionTile({
    required BuildContext dialogContext,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    bool primary = false,
  }) {
    final backgroundColor = primary
        ? const Color(0xFF2C2C2C)
        : const Color(0xFFF4F4F4);
    final foregroundColor = primary ? Colors.white : const Color(0xFF222222);
    final subtitleColor = primary ? Colors.white70 : const Color(0xFF666666);

    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.of(dialogContext).pop(value),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: primary ? Colors.white12 : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: foregroundColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: foregroundColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: subtitleColor,
                        fontSize: 13,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: subtitleColor),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool?> _askDownloadAction() async {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C2C2C),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.file_download_outlined,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Download',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Abbrechen', 'Cancel'),
                    onPressed: () => Navigator.of(dialogContext).pop(null),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                tr(
                  'Was möchtest du mit der Datei machen?',
                  'What would you like to do with the file?',
                ),
                style: const TextStyle(
                  color: Color(0xFF555555),
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              _downloadActionTile(
                dialogContext: dialogContext,
                icon: Icons.ios_share_outlined,
                title: tr('Teilen', 'Share'),
                subtitle: tr(
                  'An Mail, Drive, OneDrive oder andere Apps senden',
                  'Send to Mail, Drive, OneDrive, or other apps',
                ),
                value: true,
                primary: true,
              ),
              const SizedBox(height: 10),
              _downloadActionTile(
                dialogContext: dialogContext,
                icon: Icons.save_alt_outlined,
                title: tr('Auf Gerät speichern', 'Save to device'),
                subtitle: tr(
                  'In einem Ordner auf diesem Gerät ablegen',
                  'Save in a folder on this device',
                ),
                value: false,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(null),
                  child: Text(tr('Abbrechen', 'Cancel')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareDownloadedBytes({
    required Uint8List bytes,
    required String fileName,
  }) async {
    if (!kIsWeb && Platform.isIOS) {
      await _downloadChannel.invokeMethod<void>('shareFile', {
        'bytes': bytes,
        'fileName': fileName,
      });
      return;
    }

    final box = context.findRenderObject() as RenderBox?;

    await SharePlus.instance.share(
      ShareParams(
        title: fileName,
        subject: fileName,
        files: [XFile.fromData(bytes, mimeType: 'application/dxf')],
        fileNameOverrides: [fileName],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  Future<void> _downloadWithTarget(
    String fileUrl,
    String filename, {
    required String installationType,
  }) async {
    try {
      final shareFile = await _askDownloadAction();

      if (!mounted || shareFile == null) return;

      final response = await http.get(Uri.parse(fileUrl));

      if (!mounted) return;

      if (response.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isEnglish
                  ? 'Download failed (${response.statusCode})'
                  : 'Download fehlgeschlagen (${response.statusCode})',
            ),
          ),
        );
        return;
      }

      Uint8List bytes = response.bodyBytes;
      try {
        final layerSettings = await DxfLayerPrefs.getSettings();
        if (layerSettings.enabled) {
          bytes = DxfLayerProcessor.rewriteAusschnittLayers(
            response.bodyBytes,
            falzLayer: layerSettings.falzLayer,
            gesaegtLayer: layerSettings.gesaegtLayer,
            auflageLayer: layerSettings.auflageLayer,
            unterbauLayer: layerSettings.unterbauLayer,
            bohrungLayer: layerSettings.bohrungLayer,
            konstruktionLayer: layerSettings.konstruktionLayer,
            falzColor: layerSettings.falzColor,
            gesaegtColor: layerSettings.gesaegtColor,
            auflageColor: layerSettings.auflageColor,
            unterbauColor: layerSettings.unterbauColor,
            bohrungColor: layerSettings.bohrungColor,
            konstruktionColor: layerSettings.konstruktionColor,
            cutType: DxfLayerProcessor.detectCutType(installationType),
          );
        }
      } catch (_) {
        bytes = response.bodyBytes;
      }
      final String saveName = _safeDxfFileName(filename);

      if (shareFile) {
        await _shareDownloadedBytes(bytes: bytes, fileName: saveName);
        return;
      }

      String? directoryPath = await DownloadPrefs.getDownloadDir();
      String directoryLabel =
          await DownloadPrefs.getDownloadDirLabel() ?? directoryPath ?? '';

      if (!kIsWeb &&
          Platform.isAndroid &&
          directoryPath != null &&
          !directoryPath.startsWith('content://')) {
        await DownloadPrefs.clearDownloadDir();
        directoryPath = null;
        directoryLabel = '';
      }

      if (!kIsWeb &&
          Platform.isIOS &&
          directoryPath != null &&
          !directoryPath.startsWith('ios-bookmark://')) {
        await DownloadPrefs.clearDownloadDir();
        directoryPath = null;
        directoryLabel = '';
      }

      if (!mounted) return;

      if (directoryPath != null && directoryPath.isNotEmpty) {
        final reuse = await _askUseSavedDirectory(directoryLabel);

        if (!mounted) return;

        if (reuse == null) return;

        if (!reuse) {
          final picked = await _pickDownloadDirectory();
          directoryPath = picked?.value;
          directoryLabel = picked?.label ?? '';
        }
      } else {
        final picked = await _pickDownloadDirectory();
        directoryPath = picked?.value;
        directoryLabel = picked?.label ?? '';
      }

      if (!mounted) return;

      if (directoryPath == null || directoryPath.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('Ordnerauswahl abgebrochen.', 'Folder selection canceled.'),
            ),
          ),
        );
        return;
      }

      await _saveBytesToDirectory(
        bytes: bytes,
        directoryPath: directoryPath,
        fileName: saveName,
      );

      await DownloadPrefs.setDownloadDir(directoryPath);
      await DownloadPrefs.setDownloadDirLabel(directoryLabel);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isEnglish
                ? 'Saved to: $directoryLabel'
                : 'Gespeichert in: $directoryLabel',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Download oder Speichern fehlgeschlagen.',
              'Download or save failed.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _openExternalLink(String url) async {
    final uri = Uri.parse(url);

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);

    if (!mounted) return;

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isEnglish
                ? 'Could not open link: $url'
                : 'Link konnte nicht geöffnet werden: $url',
          ),
        ),
      );
    }
  }

  Future<void> _searchPdfOnWeb({required String filename}) async {
    final raw = filename.trim();

    if (raw.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Kein Dateiname für die PDF-Suche verfügbar.',
              'No file name is available for the PDF search.',
            ),
          ),
        ),
      );
      return;
    }

    final parts = raw
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final mainQuery = ['"$raw"', ...parts.map((p) => '"$p"')].join(' OR ');
    final query = '$mainQuery filetype:pdf';

    final uri = Uri.parse(
      'https://www.google.com/search?q=${Uri.encodeQueryComponent(query)}',
    );

    final ok = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);

    if (!mounted) return;

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'PDF-Suche konnte nicht geöffnet werden.',
              'Could not open the PDF search.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _reportWrongMatch(CatalogItem item) async {
    final labelNumber = _recognizedSinkLabelNumber.trim();
    final searchTerm = _activeHighlightTerm.trim().isNotEmpty
        ? _activeHighlightTerm.trim()
        : _searchController.text.trim();
    final bodyLines = [
      'ATool Fehlzuordnung melden',
      '',
      'Erkannte Nummer: ${labelNumber.isEmpty ? '-' : labelNumber}',
      'Suchbegriff: ${searchTerm.isEmpty ? '-' : searchTerm}',
      'Hersteller: ${item.manufacturer}',
      'Artikel/Datei: ${item.basename}',
      'Einbauart: ${item.type}',
      'Artikel-ID: ${item.id}',
      '',
      'Richtiger Artikel, falls bekannt:',
    ];
    final uri = Uri(
      scheme: 'mailto',
      path: 'support@adler-aufmasse.de',
      queryParameters: {
        'subject': 'ATool: Falscher Treffer',
        'body': bodyLines.join('\n'),
      },
    );

    _logSearchQuality(
      event: 'wrong_match_report',
      searchType: 'feedback',
      term: searchTerm,
      usedTerm: searchTerm,
      labelRule: _labelRuleNameForSearchTerm(searchTerm),
      recognizedLabel: labelNumber,
      resultCount: _results.length,
      results: [item],
      ocrTerms: _ocrBoxTexts,
    );

    await _openExternalLink(uri.toString());
  }

  Future<void> _reportMissingItem() async {
    final searchTerm = _activeHighlightTerm.trim().isNotEmpty
        ? _activeHighlightTerm.trim()
        : _searchController.text.trim();
    final ocrTerms = _ocrBoxTexts
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(12)
        .join(', ');
    final bodyLines = [
      'ATool fehlenden Artikel melden',
      '',
      'Suchbegriff: ${searchTerm.isEmpty ? '-' : searchTerm}',
      'Erkannte OCR-Begriffe: ${ocrTerms.isEmpty ? '-' : ocrTerms}',
      '',
      'Hersteller, falls bekannt:',
      'Modell/Artikelnummer, falls bekannt:',
      'Hinweis:',
    ];
    final uri = Uri(
      scheme: 'mailto',
      path: 'support@adler-aufmasse.de',
      queryParameters: {
        'subject': 'ATool: Artikel fehlt',
        'body': bodyLines.join('\n'),
      },
    );

    _logSearchQuality(
      event: 'missing_item_report',
      searchType: 'feedback',
      term: searchTerm,
      usedTerm: searchTerm,
      labelRule: _labelRuleNameForSearchTerm(searchTerm),
      recognizedLabel: _recognizedSinkLabelNumber,
      resultCount: 0,
      ocrTerms: _ocrBoxTexts,
    );

    await _openExternalLink(uri.toString());
  }

  Widget _highlightedText(
    String text,
    String search, {
    TextStyle? style,
    TextStyle? highlightStyle,
  }) {
    final q = search.trim();
    if (q.isEmpty) return Text(text, style: style);

    final lowerText = text.toLowerCase();
    final lowerQ = q.toLowerCase();
    final start = lowerText.indexOf(lowerQ);

    if (start < 0) return Text(text, style: style);

    final end = start + q.length;

    return RichText(
      text: TextSpan(
        style: style ?? const TextStyle(color: Colors.black),
        children: [
          TextSpan(text: text.substring(0, start)),
          TextSpan(
            text: text.substring(start, end),
            style:
                highlightStyle ??
                const TextStyle(
                  backgroundColor: Color(0xFFD9D9D9),
                  color: Colors.black,
                  fontWeight: FontWeight.w700,
                ),
          ),
          TextSpan(text: text.substring(end)),
        ],
      ),
    );
  }

  Widget _ocrSuggestionPanel({required double maxHeight}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              setState(() {
                _showOcrSuggestions = !_showOcrSuggestions;
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _results.isEmpty
                          ? tr('OCR-Begriffe anzeigen', 'Show OCR terms')
                          : tr('Weitere OCR-Begriffe', 'More OCR terms'),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Icon(
                    _showOcrSuggestions ? Icons.expand_less : Icons.expand_more,
                  ),
                ],
              ),
            ),
          ),
          if (_showOcrSuggestions) ...[
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _ocrBoxTexts.take(12).map((text) {
                    return ActionChip(
                      label: Text(text),
                      onPressed: () => _applyOcrSuggestion(text),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _recognizedSinkLabelNumberPanel() {
    final recognizedNumber = _recognizedSinkLabelNumber.trim();
    if (recognizedNumber.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E0E0)),
      ),
      child: Row(
        children: [
          const Icon(Icons.tag_outlined, color: Color(0xFF2C2C2C)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('Erkannte Nummer', 'Detected number'),
                  style: const TextStyle(
                    color: Color(0xFF666666),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  recognizedNumber,
                  style: const TextStyle(
                    color: Color(0xFF111111),
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sinkLabelMatchWarningPanel() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFFCC80)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_outlined, color: Color(0xFFE65100)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              tr(
                'Achtung: Hersteller-Etikett - passende Treffer. Bitte Modell und Variante prüfen.',
                'Attention: manufacturer label - matching results. Please verify model and variant.',
              ),
              style: const TextStyle(
                color: Color(0xFF5D4037),
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rawSearch = _searchController.text.trim();
    final search = _activeHighlightTerm.isNotEmpty
        ? _activeHighlightTerm
        : rawSearch;
    final compactHeight = MediaQuery.sizeOf(context).height < 430;
    final compactResultsChrome =
        _resultChromeCollapsed && _results.isNotEmpty && !_searchLoading;
    final ocrSuggestionsMaxHeight = MediaQuery.sizeOf(context).height * 0.32;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2C2C2C),
        foregroundColor: Colors.white,
        toolbarHeight: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              color: const Color(0xFF2C2C2C),
              padding: compactResultsChrome
                  ? const EdgeInsets.fromLTRB(12, 8, 12, 10)
                  : compactHeight
                  ? const EdgeInsets.fromLTRB(12, 6, 12, 8)
                  : const EdgeInsets.fromLTRB(16, 12, 16, 18),
              child: Column(
                children: [
                  if (!compactResultsChrome) ...[
                    Center(
                      child: Image.network(
                        'https://adler-aufmasse.de/wp-content/uploads/2026/04/ATOOL_Trans_Weiss.png',
                        height: compactHeight ? 38 : 100,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Text(
                            'ATool',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: compactHeight ? 4 : 8),
                  ],
                  Row(
                    children: [
                      _HeaderActionButton(
                        icon: Icons.camera_alt_outlined,
                        onTap: _showOcrPicker,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          autofocus: false,
                          autocorrect: false,
                          enableSuggestions: false,
                          smartDashesType: SmartDashesType.disabled,
                          smartQuotesType: SmartQuotesType.disabled,
                          textCapitalization: TextCapitalization.none,
                          textInputAction: TextInputAction.search,
                          onTap: () {
                            if (!_resultChromeCollapsed) return;
                            setState(() {
                              _resultChromeCollapsed = false;
                            });
                          },
                          onTapOutside: (_) {
                            FocusManager.instance.primaryFocus?.unfocus();
                          },
                          onSubmitted: (value) {
                            FocusManager.instance.primaryFocus?.unfocus();
                            unawaited(_handleSearchDirect(value));
                          },
                          decoration: InputDecoration(
                            hintText: isEnglish
                                ? 'Enter item number (min. $manualSearchLen characters)…'
                                : 'Artikelnummer eingeben (min. $manualSearchLen Zeichen)…',
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 14,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _HeaderActionButton(
                        icon: Icons.settings_outlined,
                        onTap: _showInfoDialog,
                        smallIcon: true,
                      ),
                    ],
                  ),
                  if (!compactResultsChrome)
                    SizedBox(height: compactHeight ? 6 : 14),
                  if (!compactHeight && !compactResultsChrome)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _countLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : RichText(
                              text: TextSpan(
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                                children: [
                                  TextSpan(
                                    text: tr(
                                      'Verfügbare Ausschnitte: ',
                                      'Available cut-outs: ',
                                    ),
                                  ),
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF444444),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '${_dwgDisplayCount ?? _totalCount ?? 0}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                ],
              ),
            ),

            Expanded(
              child: _pageLoading
                  ? const Center(child: CircularProgressIndicator())
                  : Padding(
                      padding: compactHeight
                          ? const EdgeInsets.all(8)
                          : const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          if (_searchLoading)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _ocrSearchActive
                                  ? Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Colors.white,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: const Color(0xFFE0E0E0),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              tr(
                                                'OCR-Suche läuft…',
                                                'OCR search running…',
                                              ),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          ElevatedButton.icon(
                                            onPressed: _cancelOcrSearch,
                                            icon: const Icon(
                                              Icons.stop_circle_outlined,
                                            ),
                                            label: Text(
                                              tr('OCR abbrechen', 'Cancel OCR'),
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFF2C2C2C,
                                              ),
                                              foregroundColor: Colors.white,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : Text(tr('Suche läuft…', 'Search running…')),
                            ),
                          if (_message.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                _message,
                                style: TextStyle(
                                  color: _results.isNotEmpty
                                      ? const Color(0xFF2E7D32)
                                      : Colors.red,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (_ocrBoxTexts.isNotEmpty && _results.isEmpty)
                            _ocrSuggestionPanel(
                              maxHeight: ocrSuggestionsMaxHeight,
                            ),
                          if (_showSinkLabelMatchWarning && _results.isNotEmpty)
                            _recognizedSinkLabelNumberPanel(),
                          if (_showSinkLabelMatchWarning && _results.isNotEmpty)
                            _sinkLabelMatchWarningPanel(),
                          if (!_searchLoading &&
                              _results.isEmpty &&
                              rawSearch.length >= manualSearchLen)
                            Padding(
                              padding: const EdgeInsets.only(top: 20),
                              child: Column(
                                children: [
                                  Text(
                                    tr(
                                      'Artikel noch nicht hinterlegt.',
                                      'Item not yet available.',
                                    ),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      color: Color(0xFF666666),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  OutlinedButton.icon(
                                    onPressed: _reportMissingItem,
                                    icon: const Icon(
                                      Icons.report_problem_outlined,
                                    ),
                                    label: Text(
                                      tr('Artikel melden', 'Report item'),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF2C2C2C),
                                      side: const BorderSide(
                                        color: Color(0xFF2C2C2C),
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Expanded(
                            child: ListView.builder(
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              itemCount:
                                  _results.length +
                                  (_ocrBoxTexts.isNotEmpty &&
                                          _results.isNotEmpty
                                      ? 1
                                      : 0),
                              itemBuilder: (context, index) {
                                if (_ocrBoxTexts.isNotEmpty &&
                                    _results.isNotEmpty &&
                                    index == _results.length) {
                                  return _ocrSuggestionPanel(
                                    maxHeight: ocrSuggestionsMaxHeight,
                                  );
                                }

                                final item = _results[index];
                                final filename = item.basename;
                                final einbauTyp = item.type;
                                final installationIconType =
                                    _dxfCutIconTypeForCatalogType(einbauTyp);
                                final hersteller = item.manufacturer;
                                final imageUrlSafe = item.jpgUrl ?? '';
                                final downloadUrlSafe = item.dxfUrl ?? '';

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 15),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF9F9F9),
                                    borderRadius: BorderRadius.circular(8),
                                    boxShadow: const [
                                      BoxShadow(
                                        blurRadius: 6,
                                        color: Color(0x11000000),
                                        offset: Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Stack(
                                        children: [
                                          Padding(
                                            padding: EdgeInsets.only(
                                              right:
                                                  installationIconType != null
                                                  ? 58
                                                  : 0,
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                if (hersteller.isNotEmpty)
                                                  _highlightedText(
                                                    hersteller,
                                                    search,
                                                    style: const TextStyle(
                                                      color: Color(0xFF666666),
                                                      fontSize: 13,
                                                    ),
                                                  ),
                                                if (hersteller.isNotEmpty)
                                                  const SizedBox(height: 2),
                                                _highlightedText(
                                                  filename,
                                                  search,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 16,
                                                    color: Colors.black,
                                                  ),
                                                ),
                                                if (einbauTyp.isNotEmpty) ...[
                                                  const SizedBox(height: 2),
                                                  _highlightedText(
                                                    einbauTyp,
                                                    search,
                                                    style: const TextStyle(
                                                      color: Color(0xFF666666),
                                                      fontSize: 13,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          if (installationIconType != null)
                                            Positioned(
                                              top: hersteller.isNotEmpty
                                                  ? 4
                                                  : 0,
                                              right: 0,
                                              child: _CatalogInstallationIcon(
                                                type: installationIconType,
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      LayoutBuilder(
                                        builder: (context, constraints) {
                                          final useVerticalButtons =
                                              constraints.maxWidth < 520;

                                          final viewButton =
                                              ElevatedButton.icon(
                                                onPressed:
                                                    item.jpgExists &&
                                                        imageUrlSafe.isNotEmpty
                                                    ? () {
                                                        _openImageViewer(
                                                          imageUrlSafe,
                                                          filename,
                                                        );
                                                      }
                                                    : null,
                                                icon: const Icon(
                                                  Icons.remove_red_eye_outlined,
                                                ),
                                                label: Text(
                                                  tr('Ansehen', 'View'),
                                                ),
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: const Color(
                                                    0xFF2C2C2C,
                                                  ),
                                                  foregroundColor: Colors.white,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          6,
                                                        ),
                                                  ),
                                                ),
                                              );

                                          final downloadButton =
                                              ElevatedButton.icon(
                                                onPressed:
                                                    item.dxfExists &&
                                                        downloadUrlSafe
                                                            .isNotEmpty
                                                    ? () {
                                                        _downloadWithTarget(
                                                          downloadUrlSafe,
                                                          filename,
                                                          installationType:
                                                              einbauTyp,
                                                        );
                                                      }
                                                    : null,
                                                icon: const Icon(
                                                  Icons.download_outlined,
                                                ),
                                                label: const Text('Download'),
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: const Color(
                                                    0xFF444444,
                                                  ),
                                                  foregroundColor: Colors.white,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          6,
                                                        ),
                                                  ),
                                                ),
                                              );

                                          final pdfButton = ElevatedButton.icon(
                                            onPressed: () {
                                              _searchPdfOnWeb(
                                                filename: filename,
                                              );
                                            },
                                            icon: const Icon(
                                              Icons.picture_as_pdf_outlined,
                                            ),
                                            label: Text(
                                              tr('PDF suchen', 'Search PDF'),
                                            ),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFF666666,
                                              ),
                                              foregroundColor: Colors.white,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                              ),
                                            ),
                                          );

                                          if (useVerticalButtons) {
                                            return Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                viewButton,
                                                const SizedBox(height: 8),
                                                downloadButton,
                                                const SizedBox(height: 8),
                                                pdfButton,
                                              ],
                                            );
                                          }

                                          return Row(
                                            children: [
                                              Expanded(child: viewButton),
                                              const SizedBox(width: 8),
                                              Expanded(child: downloadButton),
                                              const SizedBox(width: 8),
                                              Expanded(child: pdfButton),
                                            ],
                                          );
                                        },
                                      ),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton.icon(
                                          onPressed: () =>
                                              _reportWrongMatch(item),
                                          icon: const Icon(
                                            Icons.report_problem_outlined,
                                            size: 18,
                                          ),
                                          label: Text(
                                            tr(
                                              'Falscher Treffer?',
                                              'Wrong match?',
                                            ),
                                          ),
                                          style: TextButton.styleFrom(
                                            foregroundColor: const Color(
                                              0xFF666666,
                                            ),
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            if (!compactHeight)
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                color: const Color(0xFF2C2C2C),
                padding: compactResultsChrome
                    ? const EdgeInsets.symmetric(horizontal: 20, vertical: 6)
                    : const EdgeInsets.fromLTRB(20, 10, 20, 12),
                child: compactResultsChrome
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Tooltip(
                            message: 'info@adler-aufmasse.de',
                            child: IconButton(
                              onPressed: () => _openExternalLink(
                                'mailto:info@adler-aufmasse.de',
                              ),
                              icon: const Icon(Icons.mail_outline),
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Tooltip(
                            message: 'www.adler-aufmasse.de',
                            child: IconButton(
                              onPressed: () => _openExternalLink(
                                'https://www.adler-aufmasse.de',
                              ),
                              icon: const Icon(Icons.language),
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 18),
                          Image.network(
                            'https://adler-aufmasse.de/wp-content/themes/mae/img/logo.png',
                            height: 32,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _FooterLinkRow(
                                  icon: Icons.mail_outline,
                                  text: 'info@adler-aufmasse.de',
                                  onTap: () => _openExternalLink(
                                    'mailto:info@adler-aufmasse.de',
                                  ),
                                ),
                                const SizedBox(height: 6),
                                _FooterLinkRow(
                                  icon: Icons.language,
                                  text: 'www.adler-aufmasse.de',
                                  onTap: () => _openExternalLink(
                                    'https://www.adler-aufmasse.de',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Image.network(
                            'https://adler-aufmasse.de/wp-content/themes/mae/img/logo.png',
                            height: 70,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ],
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

class InfoLicensePage extends StatefulWidget {
  const InfoLicensePage({super.key});

  @override
  State<InfoLicensePage> createState() => _InfoLicensePageState();
}

class _InfoLicensePageState extends State<InfoLicensePage> {
  bool _loading = true;
  String _message = '';
  Map<String, dynamic>? _data;
  String _deviceUuid = '';
  DeviceMeta? _deviceMeta;
  String _downloadDir = '';
  String _downloadDirLabel = '';
  int _catalogCount = 0;
  DateTime? _catalogCachedAt;
  DateTime? _lastLicenseCheck;
  int _offlineDaysRemaining = 0;
  OfflineImageStatus _offlineImageStatus = const OfflineImageStatus(
    imageCount: 0,
    totalBytes: 0,
    lastUpdated: null,
  );
  DxfLayerSettings _dxfLayerSettings = const DxfLayerSettings(
    enabled: false,
    falzLayer: DxfLayerPrefs.defaultFalzLayer,
    gesaegtLayer: DxfLayerPrefs.defaultGesaegtLayer,
    auflageLayer: DxfLayerPrefs.defaultAuflageLayer,
    unterbauLayer: DxfLayerPrefs.defaultUnterbauLayer,
    bohrungLayer: DxfLayerPrefs.defaultBohrungLayer,
    konstruktionLayer: DxfLayerPrefs.defaultKonstruktionLayer,
    falzColor: DxfLayerPrefs.defaultLayerColor,
    gesaegtColor: DxfLayerPrefs.defaultLayerColor,
    auflageColor: DxfLayerPrefs.defaultLayerColor,
    unterbauColor: DxfLayerPrefs.defaultLayerColor,
    bohrungColor: DxfLayerPrefs.defaultLayerColor,
    konstruktionColor: DxfLayerPrefs.defaultLayerColor,
  );

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final uuid = await AppStorage.getOrCreateDeviceUuid();
      final meta = await DeviceMetaService.load();
      final lastDir = await DownloadPrefs.getDownloadDir();
      final lastDirLabel = await DownloadPrefs.getDownloadDirLabel();
      final dxfLayerSettings = await DxfLayerPrefs.getSettings();
      final offlineImageStatus = await OfflineImageStore.getStatus();
      final cachedCatalogJson = await CatalogCachePrefs.getCatalogJson();
      final cachedCatalog = cachedCatalogJson == null || cachedCatalogJson.isEmpty
          ? <CatalogItem>[]
          : await compute(_parseCatalogItemsInBackground, cachedCatalogJson);
      final catalogCachedAt = await CatalogCachePrefs.getCatalogCachedAt();
      Map<String, dynamic>? data;
      var licenseMessage = '';

      try {
        final response = await ApiService.getLicenseStatus();
        if (response['success'] == true) {
          data = response;
          await LicenseCheckPrefs.markSuccessfulCheckNow();
        } else {
          licenseMessage =
              (response['message'] ??
                      tr(
                        'Lizenzstatus konnte nicht geladen werden.',
                        'Could not load the license status.',
                      ))
                  .toString();
        }
      } catch (_) {
        if (!await LicenseCheckPrefs.isWithinOfflineGracePeriod()) {
          licenseMessage = tr(
            'Lizenzstatus konnte nicht geladen werden.',
            'Could not load the license status.',
          );
        }
      }
      final offlineDaysRemaining =
          await LicenseCheckPrefs.getOfflineDaysRemaining();
      final lastLicenseValue = await LicenseCheckPrefs.getLastSuccessfulCheck();

      if (!mounted) return;

      setState(() {
        _deviceUuid = uuid;
        _deviceMeta = meta;
        _downloadDir = lastDir ?? '';
        _downloadDirLabel = lastDirLabel ?? '';
        _catalogCount = cachedCatalog.length;
        _catalogCachedAt = catalogCachedAt;
        _offlineDaysRemaining = offlineDaysRemaining;
        _lastLicenseCheck = lastLicenseValue == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(lastLicenseValue);
        _dxfLayerSettings = dxfLayerSettings;
        _offlineImageStatus = offlineImageStatus;
        if (data != null) {
          _data = data;
        }
        _message = licenseMessage;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message = tr(
          'Info-Bereich konnte nicht geladen werden.',
          'Could not load the information section.',
        );
        _loading = false;
      });
    }
  }

  Future<void> _logout() async {
    await ApiService.logout();

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  void _showLicenseAgreement() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr('Hinweise zur Nutzung', 'Usage information')),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(
                    'ATool unterstützt bei der Suche nach Artikeln, Zeichnungen und Produktinformationen.',
                    'ATool helps you search for items, drawings, and product information.',
                  ),
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 18),

                _infoSection(
                  icon: Icons.info_outline,
                  title: tr('Was macht ATool?', 'What does ATool do?'),
                  text: tr(
                    'Die App dient als internes Hilfsmittel zur schnellen Orientierung im Arbeitsalltag und unterstützt bei der Identifikation von Artikeln und zugehörigen Dateien.',
                    'The app is an internal tool for quick guidance in everyday work and helps identify items and related files.',
                  ),
                ),
                const SizedBox(height: 14),

                _infoSection(
                  icon: Icons.verified_outlined,
                  title: tr('Hinweis zur Datenqualität', 'Data quality notice'),
                  text: tr(
                    'Die angezeigten Inhalte werden sorgfältig bereitgestellt. Dennoch können Informationen im Einzelfall unvollständig, veraltet oder fehlerhaft sein. Verbindlich bleiben die jeweils freigegebenen technischen Unterlagen und internen Datenquellen.',
                    'The displayed content is prepared with care. However, individual information may be incomplete, outdated, or incorrect. Approved technical documents and internal data sources remain authoritative.',
                  ),
                ),
                const SizedBox(height: 14),

                _infoSection(
                  icon: Icons.document_scanner_outlined,
                  title: tr(
                    'Hinweis zur OCR-Erkennung',
                    'OCR recognition notice',
                  ),
                  text: tr(
                    'Die automatische Texterkennung erleichtert das Erfassen von Aufklebern und Beschriftungen. Je nach Bildqualität, Perspektive oder Verschmutzung können jedoch fehlerhafte oder unvollständige Ergebnisse entstehen. Erkannte Suchbegriffe und Treffer sollten deshalb vor der weiteren Verwendung geprüft werden.',
                    'Automatic text recognition makes it easier to capture labels and markings. Image quality, perspective, or dirt may cause incorrect or incomplete results. Please verify recognized terms and matches before using them.',
                  ),
                ),
                const SizedBox(height: 14),

                _infoSection(
                  icon: Icons.business_center_outlined,
                  title: tr('Nutzung', 'Use'),
                  text: tr(
                    'Die Anwendung ist ausschließlich für den vorgesehenen betrieblichen Einsatz bestimmt.',
                    'The application is intended solely for its designated business use.',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(tr('Schließen', 'Close')),
          ),
        ],
      ),
    );
  }

  Future<void> _openPrivacyPolicy() async {
    final uri = Uri.parse(AppConfig.privacyPolicyUrl);
    bool opened = false;

    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }

    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Datenschutzseite konnte nicht geöffnet werden.',
              'Could not open the privacy policy.',
            ),
          ),
        ),
      );
    }
  }

  Widget _infoSection({
    required IconData icon,
    required String title,
    required String text,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 20, color: const Color(0xFF2C2C2C)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _setDxfLayerProcessingEnabled(bool enabled) async {
    final settings = _dxfLayerSettings.copyWith(enabled: enabled);
    await DxfLayerPrefs.setSettings(settings);

    if (!mounted) return;

    setState(() {
      _dxfLayerSettings = settings;
    });
  }

  Future<void> _setLanguage(AppLanguage language) async {
    await appLanguageController.change(language);
    if (!mounted) return;
    setState(() {});
  }

  void _openAppHelp() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const AppHelpPage()));
  }

  void _showOcrRules() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('OCR-Regeln', 'OCR rules'),
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 14),
              _OcrRuleInfoRow(
                title: 'Franke',
                value: tr(
                  'Becken-Etikett: Nummer im Format 000.0000.000',
                  'Sink label: number in 000.0000.000 format',
                ),
              ),
              const _SettingsDivider(),
              _OcrRuleInfoRow(
                title: 'Blanco',
                value: tr(
                  'Groesste 00-Artikelnummer auf dem Etikett',
                  'Largest 00 item number on the label',
                ),
              ),
              const _SettingsDivider(),
              _OcrRuleInfoRow(
                title: 'BORA',
                value: tr(
                  'Model-Zeile, z.B. PURMU2R oder PUXU2R',
                  'Model line, e.g. PURMU2R or PUXU2R',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _chooseLanguage() async {
    final language = await showModalBottomSheet<AppLanguage>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('Sprache auswählen', 'Select language'),
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              _LanguageChoiceTile(
                title: 'Deutsch',
                selected: appLanguageController.value == AppLanguage.german,
                onTap: () => Navigator.of(sheetContext).pop(AppLanguage.german),
              ),
              _LanguageChoiceTile(
                title: 'English',
                selected: appLanguageController.value == AppLanguage.english,
                onTap: () =>
                    Navigator.of(sheetContext).pop(AppLanguage.english),
              ),
            ],
          ),
        ),
      ),
    );

    if (language != null) await _setLanguage(language);
  }

  Future<({String value, String label})?> _pickDownloadDirectory() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final result = await _MainSearchPageState._downloadChannel
            .invokeMapMethod<String, dynamic>('pickDownloadDirectory');
        final uri = result?['uri']?.toString() ?? '';
        final name = result?['name']?.toString() ?? '';
        if (uri.isEmpty) return null;
        return (
          value: uri,
          label: name.isNotEmpty
              ? name
              : tr('Ausgewählter Ordner', 'Selected folder'),
        );
      }

      if (!kIsWeb && Platform.isIOS) {
        final result = await _MainSearchPageState._downloadChannel
            .invokeMapMethod<String, dynamic>('pickDownloadDirectory');
        final bookmark = result?['bookmark']?.toString() ?? '';
        final name = result?['name']?.toString() ?? '';
        if (bookmark.isEmpty) return null;
        return (
          value: bookmark,
          label: name.isNotEmpty
              ? name
              : tr('Ausgewählter Ordner', 'Selected folder'),
        );
      }

      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: tr('Download-Ordner wählen', 'Select download folder'),
      );
      if (dir == null || dir.isEmpty) return null;
      return (value: dir, label: dir);
    } catch (_) {
      return null;
    }
  }

  Future<void> _changeDownloadDirectory() async {
    final picked = await _pickDownloadDirectory();
    if (picked == null || !mounted) return;

    await DownloadPrefs.setDownloadDir(picked.value);
    await DownloadPrefs.setDownloadDirLabel(picked.label);
    if (!mounted) return;

    setState(() {
      _downloadDir = picked.value;
      _downloadDirLabel = picked.label;
    });
  }

  Future<void> _resetDownloadDirectory() async {
    await DownloadPrefs.clearDownloadDir();
    if (!mounted) return;

    setState(() {
      _downloadDir = '';
      _downloadDirLabel = '';
    });
  }

  Future<void> _showDownloadSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('Download-Ziel', 'Download destination'),
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F4F4),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.folder_open_outlined),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _downloadDirDisplay,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_changeDownloadDirectory());
                },
                icon: const Icon(Icons.folder_outlined),
                label: Text(tr('Ordner ändern', 'Change folder')),
              ),
              if (_downloadDir.isNotEmpty) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_resetDownloadDirectory());
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: Text(
                    tr('Gespeicherten Ordner löschen', 'Clear saved folder'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDxfSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _DxfSettingsPage(
          initialSettings: _dxfLayerSettings,
          validate: _validateDxfLayerSettings,
        ),
      ),
    );

    final settings = await DxfLayerPrefs.getSettings();
    if (!mounted) return;
    setState(() => _dxfLayerSettings = settings);
  }

  Future<void> _openOfflineImages() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const _OfflineImagesPage()));
    final status = await OfflineImageStore.getStatus();
    if (mounted) setState(() => _offlineImageStatus = status);
  }

  Future<void> _openSiteReadinessCheck() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const _SiteReadinessPage()));
    final status = await OfflineImageStore.getStatus();
    if (mounted) setState(() => _offlineImageStatus = status);
  }

  void _openAccountDetails() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _AccountLicensePage(
          data: _data,
          deviceUuid: _deviceUuid,
          deviceMeta: _deviceMeta,
        ),
      ),
    );
  }

  void _openLegalDetails() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _LegalSettingsPage(
          onShowUsageInformation: _showLicenseAgreement,
          onOpenPrivacyPolicy: _openPrivacyPolicy,
        ),
      ),
    );
  }

  String? _validateDxfLayerSettings(
    String falzLayer,
    String gesaegtLayer,
    String auflageLayer,
    String unterbauLayer,
    String bohrungLayer,
    String konstruktionLayer,
    int? falzColor,
    int? gesaegtColor,
    int? auflageColor,
    int? unterbauColor,
    int? bohrungColor,
    int? konstruktionColor,
  ) {
    final falzError = _validateDxfLayerName(falzLayer);
    if (falzError != null) return '${tr('Falz', 'Rebate')}: $falzError';

    final gesaegtError = _validateDxfLayerName(gesaegtLayer);
    if (gesaegtError != null) {
      return '${tr('Gesägt', 'Saw cut')}: $gesaegtError';
    }

    final auflageError = _validateDxfLayerName(auflageLayer);
    if (auflageError != null) {
      return '${tr('Auflage', 'Support')}: $auflageError';
    }

    final unterbauError = _validateDxfLayerName(unterbauLayer);
    if (unterbauError != null) {
      return '${tr('Unterbau', 'Substructure')}: $unterbauError';
    }

    final bohrungError = _validateDxfLayerName(bohrungLayer);
    if (bohrungError != null) {
      return '${tr('Bohrungen', 'Drill holes')}: $bohrungError';
    }

    final konstruktionError = _validateDxfLayerName(konstruktionLayer);
    if (konstruktionError != null) {
      return '${tr('Konstruktion', 'Construction')}: $konstruktionError';
    }

    final colorError = _validateDxfColors({
      'Falz': falzColor,
      'Gesägt': gesaegtColor,
      'Auflage': auflageColor,
      'Unterbau': unterbauColor,
      'Bohrungen': bohrungColor,
      'Konstruktion': konstruktionColor,
    });
    if (colorError != null) return colorError;

    if (falzLayer.toUpperCase() == gesaegtLayer.toUpperCase()) {
      return tr(
        'Die beiden Ziellayer müssen unterschiedlich sein.',
        'The two target layers must be different.',
      );
    }

    return null;
  }

  String? _validateDxfColors(Map<String, int?> colors) {
    for (final entry in colors.entries) {
      final color = entry.value;

      if (color == null) {
        return isEnglish
            ? '${entry.key}: Enter a color from 1 to 255.'
            : '${entry.key}: Bitte eine Farbe von 1 bis 255 eintragen.';
      }

      if (color < 1 || color > 255) {
        return isEnglish
            ? '${entry.key}: The color must be between 1 and 255.'
            : '${entry.key}: Die Farbe muss zwischen 1 und 255 liegen.';
      }
    }

    return null;
  }

  String? _validateDxfLayerName(String layerName) {
    if (layerName.isEmpty) {
      return tr('Bitte einen Layernamen eintragen.', 'Enter a layer name.');
    }
    if (layerName.contains(RegExp(r'\s'))) {
      return tr(
        'Achtung: Es dürfen keine Leerzeichen im Layernamen vorhanden sein.',
        'Layer names must not contain spaces.',
      );
    }
    if (layerName.contains(RegExp(r'[<>/":;?*|=]'))) {
      return tr(
        'Der Layername enthält ein ungültiges Zeichen.',
        'The layer name contains an invalid character.',
      );
    }
    if (layerName.contains('\n') || layerName.contains('\r')) {
      return tr(
        'Der Layername darf keinen Zeilenumbruch enthalten.',
        'The layer name must not contain a line break.',
      );
    }

    try {
      latin1.encode(layerName);
    } catch (_) {
      return tr(
        'Der Layername enthält ein Zeichen, das DXF nicht speichern kann.',
        'The layer name contains a character that DXF cannot store.',
      );
    }

    return null;
  }

  String get _downloadDirDisplay {
    if (_downloadDir.isEmpty) return tr('Noch nicht gewählt', 'Not selected');

    final label = _downloadDirLabel.trim();
    if (label.isNotEmpty && !label.startsWith('ios-bookmark://')) {
      return label;
    }

    if (_downloadDir.startsWith('ios-bookmark://')) {
      return tr('Ausgewählter Ordner', 'Selected folder');
    }

    return _downloadDir;
  }

  String _formatSettingsDate(DateTime? value) {
    if (value == null) return tr('Noch nie', 'Never');
    final date = MaterialLocalizations.of(context).formatMediumDate(value);
    final time = TimeOfDay.fromDateTime(value).format(context);
    return '$date Â· $time';
  }

  @override
  Widget build(BuildContext context) {
    final firm = _data?['firm'] as Map<String, dynamic>?;
    final user = _data?['user'] as Map<String, dynamic>?;
    final firmStatus = (firm?['status'] ?? '').toString();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(tr('Einstellungen', 'Settings')),
        actions: [
          IconButton(
            tooltip: tr('Aktualisieren', 'Refresh'),
            onPressed: _init,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_message.isNotEmpty)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.red.withValues(alpha: 0.25),
                              ),
                            ),
                            child: Text(
                              _message,
                              style: const TextStyle(
                                color: Colors.red,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        Text(
                          tr(
                            'ATool nach deinen Bedürfnissen einrichten.',
                            'Set up ATool to suit your workflow.',
                          ),
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 22),
                        _SettingsSection(
                          title: tr('STATUS', 'STATUS'),
                          children: [
                            _ReadinessRow(
                              icon: Icons.inventory_2_outlined,
                              title: tr('Artikelkatalog', 'Item catalog'),
                              ready: _catalogCount > 0,
                              warning: false,
                              value: _catalogCount > 0
                                  ? isEnglish
                                        ? '$_catalogCount items'
                                        : '$_catalogCount Artikel'
                                  : tr('Nicht verfÃ¼gbar', 'Not available'),
                              detail: _formatSettingsDate(_catalogCachedAt),
                            ),
                            const _SettingsDivider(),
                            _ReadinessRow(
                              icon: Icons.photo_library_outlined,
                              title: tr('Offline-Bilder', 'Offline images'),
                              ready: _offlineImageStatus.imageCount > 0,
                              warning: false,
                              value: _offlineImageStatus.imageCount == 0
                                  ? tr(
                                      'Keine Bilder gespeichert',
                                      'No images saved',
                                    )
                                  : isEnglish
                                  ? '${_offlineImageStatus.imageCount} images'
                                  : '${_offlineImageStatus.imageCount} Bilder',
                              detail: _formatStorageSize(
                                _offlineImageStatus.totalBytes,
                              ),
                            ),
                            const _SettingsDivider(),
                            _ReadinessRow(
                              icon: Icons.verified_user_outlined,
                              title: tr('Offline-Lizenz', 'Offline license'),
                              ready: _offlineDaysRemaining > 0,
                              warning: false,
                              value: _offlineDaysRemaining > 0
                                  ? isEnglish
                                        ? '$_offlineDaysRemaining days remaining'
                                        : 'Noch $_offlineDaysRemaining Tage'
                                  : tr(
                                      'Erneute PrÃ¼fung nÃ¶tig',
                                      'New check required',
                                    ),
                              detail: _formatSettingsDate(_lastLicenseCheck),
                            ),
                            const _SettingsDivider(),
                            _ReadinessRow(
                              icon: Icons.info_outline,
                              title: tr('App-Version', 'App version'),
                              ready: true,
                              warning: false,
                              value: _deviceMeta?.appVersion ?? '-',
                              detail: _deviceMeta?.osVersion ?? '',
                            ),
                          ],
                        ),
                        const SizedBox(height: 22),
                        _SettingsSection(
                          title: tr('SUCHE & OCR', 'SEARCH & OCR'),
                          children: [
                            _SettingsTile(
                              icon: Icons.health_and_safety_outlined,
                              title: tr(
                                'Baustellen-Check',
                                'Site readiness check',
                              ),
                              subtitle: tr(
                                'Lizenz, Katalog und Offline-Bilder prüfen',
                                'Check license, catalog, and offline images',
                              ),
                              onTap: _openSiteReadinessCheck,
                            ),
                            const _SettingsDivider(),
                            _SettingsTile(
                              icon: Icons.document_scanner_outlined,
                              title: tr('OCR-Regeln', 'OCR rules'),
                              subtitle: tr(
                                'Franke, Blanco und BORA Etiketten erkennen',
                                'Recognize Franke, Blanco, and BORA labels',
                              ),
                              onTap: _showOcrRules,
                            ),
                            const _SettingsDivider(),
                            _SettingsTile(
                              icon: Icons.help_outline,
                              title: tr(
                                'So funktioniert ATool',
                                'How to use ATool',
                              ),
                              subtitle: tr(
                                'Oberfläche und Funktionen erklärt',
                                'Learn about the interface and features',
                              ),
                              onTap: _openAppHelp,
                            ),
                          ],
                        ),
                        const SizedBox(height: 22),
                        _SettingsSection(
                          title: tr('DATEIEN & DXF', 'FILES & DXF'),
                          children: [
                            _SettingsTile(
                              icon: Icons.folder_outlined,
                              title: tr('Download-Ordner', 'Download folder'),
                              subtitle: _downloadDirDisplay,
                              onTap: _showDownloadSettings,
                            ),
                            const _SettingsDivider(),
                            _SettingsTile(
                              icon: Icons.offline_pin_outlined,
                              title: tr('Offline-Bilder', 'Offline images'),
                              subtitle: _offlineImageStatus.imageCount == 0
                                  ? tr(
                                      'Noch keine Bilder gespeichert',
                                      'No images saved yet',
                                    )
                                  : isEnglish
                                  ? '${_offlineImageStatus.imageCount} images · ${_formatStorageSize(_offlineImageStatus.totalBytes)}'
                                  : '${_offlineImageStatus.imageCount} Bilder · ${_formatStorageSize(_offlineImageStatus.totalBytes)}',
                              onTap: _openOfflineImages,
                            ),
                            const _SettingsDivider(),
                            _SettingsTile(
                              icon: Icons.layers_outlined,
                              title: tr('DXF-Layer', 'DXF layers'),
                              subtitle: _dxfLayerSettings.enabled
                                  ? tr(
                                      'Automatische Anpassung aktiviert',
                                      'Automatic adjustment enabled',
                                    )
                                  : tr(
                                      'Originaldateien bleiben unverändert',
                                      'Original files remain unchanged',
                                    ),
                              onTap: _openDxfSettings,
                              trailing: Switch(
                                value: _dxfLayerSettings.enabled,
                                onChanged: _setDxfLayerProcessingEnabled,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 22),
                        _SettingsSection(
                          title: tr('KONTO & SUPPORT', 'ACCOUNT & SUPPORT'),
                          children: [
                            _SettingsTile(
                              icon: Icons.translate,
                              title: tr('Sprache', 'Language'),
                              value:
                                  appLanguageController.value ==
                                      AppLanguage.english
                                  ? 'English'
                                  : 'Deutsch',
                              onTap: _chooseLanguage,
                            ),
                            const _SettingsDivider(),
                            _SettingsTile(
                              icon: Icons.person_outline,
                              title: tr('Benutzer & Firma', 'User & company'),
                              subtitle: [
                                '${user?['email'] ?? ''}'.trim(),
                                '${firm?['name'] ?? ''}'.trim(),
                              ].where((value) => value.isNotEmpty).join(' · '),
                              onTap: _openAccountDetails,
                            ),
                            const _SettingsDivider(),
                            _SettingsTile(
                              icon: Icons.verified_outlined,
                              title: tr('Lizenzstatus', 'License status'),
                              subtitle: tr(
                                'Nach erfolgreicher Prüfung 30 Tage offline nutzbar',
                                'Available offline for 30 days after a successful check',
                              ),
                              onTap: _openAccountDetails,
                              trailing: _SettingsStatusBadge(
                                status: firmStatus,
                              ),
                            ),
                            const _SettingsDivider(),
                            _SettingsTile(
                              icon: Icons.privacy_tip_outlined,
                              title: tr(
                                'Datenschutz & Nutzung',
                                'Privacy & usage',
                              ),
                              onTap: _openLegalDetails,
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _logout,
                            icon: const Icon(Icons.logout),
                            label: Text(tr('Abmelden', 'Log out')),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFB3261E),
                              side: const BorderSide(color: Color(0x33B3261E)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _OcrRuleInfoRow extends StatelessWidget {
  final String title;
  final String value;

  const _OcrRuleInfoRow({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFF0F0F0),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              title.isEmpty ? '?' : title.substring(0, 1),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFF2C2C2C),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(color: Colors.black54, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: const TextStyle(
              color: Color(0xFF6B6B6B),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE4E4E4)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData? icon;
  final Widget? iconWidget;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    this.icon,
    this.iconWidget,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Widget? effectiveTrailing = trailing;
    if (effectiveTrailing == null && (value != null || onTap != null)) {
      effectiveTrailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.black54, fontSize: 14),
              ),
            ),
          if (onTap != null) ...[
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: Colors.black38),
          ],
        ],
      );
    }

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      leading: Container(
        width: 56,
        height: 52,
        decoration: BoxDecoration(
          color: const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(12),
        ),
        child:
            iconWidget ??
            Icon(
              icon ?? Icons.circle_outlined,
              color: const Color(0xFF2C2C2C),
              size: 26,
            ),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
      subtitle: subtitle == null || subtitle!.isEmpty
          ? null
          : Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
      trailing: effectiveTrailing,
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, indent: 86, color: Color(0xFFE8E8E8));
  }
}

enum _DxfCutIconType {
  auflage('assets/icons/einbauarten/auflage.svg'),
  unterbau('assets/icons/einbauarten/unterbau.svg'),
  flaechenbuendig('assets/icons/einbauarten/flaechenbuendig.svg');

  final String assetPath;

  const _DxfCutIconType(this.assetPath);
}

class _DxfCutIcon extends StatelessWidget {
  final _DxfCutIconType type;
  final double size;

  const _DxfCutIcon(this.type, {this.size = 42});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      type.assetPath,
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
  }
}

class _DxfInstallationPreview extends StatelessWidget {
  const _DxfInstallationPreview();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: const [
        Expanded(
          child: _DxfInstallationPreviewItem(
            type: _DxfCutIconType.auflage,
            label: 'Auflage',
          ),
        ),
        Expanded(
          child: _DxfInstallationPreviewItem(
            type: _DxfCutIconType.unterbau,
            label: 'Unterbau',
          ),
        ),
        Expanded(
          child: _DxfInstallationPreviewItem(
            type: _DxfCutIconType.flaechenbuendig,
            label: 'Flächenbündig',
          ),
        ),
      ],
    );
  }
}

class _DxfInstallationPreviewItem extends StatelessWidget {
  final _DxfCutIconType type;
  final String label;

  const _DxfInstallationPreviewItem({required this.type, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DxfCutIcon(type, size: 56),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _CatalogInstallationIcon extends StatelessWidget {
  final _DxfCutIconType type;

  const _CatalogInstallationIcon({required this.type});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 54,
      height: 42,
      child: Align(
        alignment: Alignment.center,
        child: _DxfCutIcon(type, size: 44),
      ),
    );
  }
}

_DxfCutIconType? _dxfCutIconTypeForCatalogType(String value) {
  final normalized = _normalizeCatalogSearchText(
    value,
  ).replaceAll(RegExp(r'[^a-z0-9]'), '');

  if (normalized.contains('unterbau')) return _DxfCutIconType.unterbau;
  if (normalized.contains('auflage') ||
      normalized.contains('slimtop') ||
      normalized.contains('aufbau')) {
    return _DxfCutIconType.auflage;
  }
  if (normalized.contains('flachenbundig') ||
      normalized.contains('flchenbndig') ||
      normalized.contains('flaechenbuendig') ||
      normalized.contains('flaechenbundig') ||
      normalized.contains('falz')) {
    return _DxfCutIconType.flaechenbuendig;
  }

  return null;
}

class _SettingsStatusBadge extends StatelessWidget {
  final String status;

  const _SettingsStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase();
    final label = switch (normalized) {
      'active' => tr('Aktiv', 'Active'),
      'blocked' => tr('Gesperrt', 'Blocked'),
      'expired' => tr('Abgelaufen', 'Expired'),
      'test' => tr('Test', 'Trial'),
      'removed' => tr('Entfernt', 'Removed'),
      _ => status.isEmpty ? '—' : status,
    };
    final color = statusColor(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _LanguageChoiceTile extends StatelessWidget {
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _LanguageChoiceTile({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: selected
          ? const Icon(Icons.check_circle, color: Color(0xFF2E7D32))
          : const Icon(Icons.circle_outlined, color: Colors.black26),
    );
  }
}

class _SiteReadinessPage extends StatefulWidget {
  const _SiteReadinessPage();

  @override
  State<_SiteReadinessPage> createState() => _SiteReadinessPageState();
}

class _SiteReadinessPageState extends State<_SiteReadinessPage> {
  List<CatalogItem> _catalog = [];
  OfflineImageStatus _imageStatus = const OfflineImageStatus(
    imageCount: 0,
    totalBytes: 0,
    lastUpdated: null,
  );
  DateTime? _lastLicenseCheck;
  DateTime? _catalogUpdatedAt;
  OfflineImageSyncCancellation? _cancellation;
  bool _loading = true;
  bool _updating = false;
  int _offlineDaysRemaining = 0;
  int _processedImages = 0;
  int _totalImages = 0;
  String _message = '';

  int get _expectedImageCount => _catalog
      .where((item) => item.jpgExists)
      .map((item) => item.jpgUrl?.trim() ?? '')
      .where((url) => url.isNotEmpty)
      .toSet()
      .length;

  bool get _licenseReady => _offlineDaysRemaining > 0;
  bool get _catalogReady => _catalog.isNotEmpty;
  bool get _imagesReady =>
      _expectedImageCount > 0 && _imageStatus.imageCount >= _expectedImageCount;
  bool get _fullyReady => _licenseReady && _catalogReady && _imagesReady;
  bool get _partlyReady =>
      !_fullyReady &&
      _licenseReady &&
      _catalogReady &&
      _imageStatus.imageCount > 0;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    try {
      final cachedJson = await CatalogCachePrefs.getCatalogJson();
      final catalog = cachedJson == null || cachedJson.isEmpty
          ? <CatalogItem>[]
          : await compute(_parseCatalogItemsInBackground, cachedJson);
      final imageStatus = await OfflineImageStore.getStatus();
      final daysRemaining = await LicenseCheckPrefs.getOfflineDaysRemaining();
      final lastLicenseValue = await LicenseCheckPrefs.getLastSuccessfulCheck();
      final catalogUpdatedAt = await CatalogCachePrefs.getCatalogCachedAt();
      if (!mounted) return;

      setState(() {
        _catalog = catalog;
        _imageStatus = imageStatus;
        _offlineDaysRemaining = daysRemaining;
        _lastLicenseCheck = lastLicenseValue == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(lastLicenseValue);
        _catalogUpdatedAt = catalogUpdatedAt;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _message = tr(
            'Der Offline-Status konnte nicht vollständig geprüft werden.',
            'The offline status could not be checked completely.',
          );
        });
      }
    }
  }

  Future<void> _updateAll() async {
    if (_updating) return;
    final cancellation = OfflineImageSyncCancellation();
    _cancellation = cancellation;
    setState(() {
      _updating = true;
      _processedImages = 0;
      _totalImages = _expectedImageCount;
      _message = '';
    });

    var connectionSucceeded = false;
    try {
      final license = await ApiService.getLicenseStatus();
      if (license['success'] == true) {
        await LicenseCheckPrefs.markSuccessfulCheckNow();
        connectionSucceeded = true;
      }
    } catch (_) {}

    List<CatalogItem> catalog = _catalog;
    try {
      final response = await http
          .get(Uri.parse(AppConfig.catalogUrl))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final freshCatalog = await compute(
          _parseCatalogItemsInBackground,
          response.body,
        );
        await CatalogCachePrefs.setCatalogJson(response.body);
        catalog = freshCatalog;
        connectionSucceeded = true;
      }
    } catch (_) {}

    if (!cancellation.isCancelled &&
        connectionSucceeded &&
        catalog.isNotEmpty) {
      await OfflineImageStore.synchronize(
        catalog,
        cancellation: cancellation,
        onProgress: (processed, total, available, failed) {
          if (!mounted) return;
          setState(() {
            _processedImages = processed;
            _totalImages = total;
          });
        },
      );
    }

    if (!mounted) return;
    await _loadStatus();
    if (!mounted) return;
    setState(() {
      _updating = false;
      _cancellation = null;
      if (cancellation.isCancelled) {
        _message = tr(
          'Aktualisierung abgebrochen. Bereits gespeicherte Daten bleiben erhalten.',
          'Update canceled. Previously saved data is kept.',
        );
      } else if (!connectionSucceeded) {
        _message = tr(
          'Keine Verbindung. Der vorhandene Offline-Stand bleibt erhalten.',
          'No connection. Existing offline data is kept.',
        );
      }
    });
  }

  String _formatDate(DateTime? value) {
    if (value == null) return tr('Noch nie', 'Never');
    final date = MaterialLocalizations.of(context).formatMediumDate(value);
    final time = TimeOfDay.fromDateTime(value).format(context);
    return '$date · $time';
  }

  @override
  Widget build(BuildContext context) {
    final statusColorValue = _fullyReady
        ? const Color(0xFF2E7D32)
        : _partlyReady
        ? const Color(0xFFB26A00)
        : const Color(0xFFB3261E);
    final statusIcon = _fullyReady
        ? Icons.check_circle_outline
        : _partlyReady
        ? Icons.warning_amber_rounded
        : Icons.error_outline;
    final statusTitle = _fullyReady
        ? tr('Offline bereit', 'Ready offline')
        : _partlyReady
        ? tr('Eingeschränkt bereit', 'Partly ready')
        : tr('Nicht offline bereit', 'Not ready offline');
    final progress = _totalImages <= 0 ? null : _processedImages / _totalImages;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(tr('Baustellen-Check', 'Site readiness check')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: statusColorValue.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: statusColorValue.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(statusIcon, color: statusColorValue, size: 38),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              statusTitle,
                              style: TextStyle(
                                color: statusColorValue,
                                fontWeight: FontWeight.bold,
                                fontSize: 20,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              tr(
                                'Prüfung für die Nutzung ohne Internet',
                                'Check for use without an internet connection',
                              ),
                              style: const TextStyle(color: Colors.black54),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (_message.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    _message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFB26A00),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                _SettingsSection(
                  title: tr('PRÜFUNG', 'CHECK'),
                  children: [
                    _ReadinessRow(
                      icon: Icons.verified_user_outlined,
                      title: tr('Offline-Lizenz', 'Offline license'),
                      ready: _licenseReady,
                      warning: false,
                      value: _licenseReady
                          ? isEnglish
                                ? '$_offlineDaysRemaining days remaining'
                                : 'Noch $_offlineDaysRemaining Tage'
                          : tr('Erneute Prüfung nötig', 'New check required'),
                      detail: _formatDate(_lastLicenseCheck),
                    ),
                    const _SettingsDivider(),
                    _ReadinessRow(
                      icon: Icons.inventory_2_outlined,
                      title: tr('Artikelkatalog', 'Item catalog'),
                      ready: _catalogReady,
                      warning: false,
                      value: _catalogReady
                          ? isEnglish
                                ? '${_catalog.length} items'
                                : '${_catalog.length} Artikel'
                          : tr('Nicht verfügbar', 'Not available'),
                      detail: _formatDate(_catalogUpdatedAt),
                    ),
                    const _SettingsDivider(),
                    _ReadinessRow(
                      icon: Icons.photo_library_outlined,
                      title: tr('Offline-Bilder', 'Offline images'),
                      ready: _imagesReady,
                      warning: !_imagesReady && _imageStatus.imageCount > 0,
                      value:
                          '${_imageStatus.imageCount} / $_expectedImageCount',
                      detail: _formatStorageSize(_imageStatus.totalBytes),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                if (_updating) ...[
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 10),
                  Text(
                    _totalImages > 0
                        ? isEnglish
                              ? 'Images: $_processedImages of $_totalImages'
                              : 'Bilder: $_processedImages von $_totalImages'
                        : tr(
                            'Lizenz und Katalog werden geprüft…',
                            'Checking license and catalog…',
                          ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _cancellation?.isCancelled == true
                        ? null
                        : _cancellation?.cancel,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(tr('Abbrechen', 'Cancel')),
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: _updateAll,
                    icon: const Icon(Icons.sync),
                    label: Text(tr('Jetzt aktualisieren', 'Update now')),
                  ),
              ],
            ),
    );
  }
}

class _ReadinessRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final String detail;
  final bool ready;
  final bool warning;

  const _ReadinessRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.detail,
    required this.ready,
    required this.warning,
  });

  @override
  Widget build(BuildContext context) {
    final color = ready
        ? const Color(0xFF2E7D32)
        : warning
        ? const Color(0xFFB26A00)
        : const Color(0xFFB3261E);
    final stateIcon = ready
        ? Icons.check_circle
        : warning
        ? Icons.warning_amber_rounded
        : Icons.cancel;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFF0F0F0),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: const Color(0xFF2C2C2C), size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  detail,
                  style: const TextStyle(color: Colors.black45, fontSize: 12),
                ),
              ],
            ),
          ),
          Icon(stateIcon, color: color),
        ],
      ),
    );
  }
}

class _OfflineImagesPage extends StatefulWidget {
  const _OfflineImagesPage();

  @override
  State<_OfflineImagesPage> createState() => _OfflineImagesPageState();
}

class _OfflineImagesPageState extends State<_OfflineImagesPage> {
  List<CatalogItem> _catalog = [];
  OfflineImageStatus _status = const OfflineImageStatus(
    imageCount: 0,
    totalBytes: 0,
    lastUpdated: null,
  );
  OfflineImageSyncCancellation? _cancellation;
  bool _loading = true;
  bool _syncing = false;
  int _processed = 0;
  int _total = 0;
  int _available = 0;
  int _failed = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final cachedJson = await CatalogCachePrefs.getCatalogJson();
      final catalog = cachedJson == null || cachedJson.isEmpty
          ? <CatalogItem>[]
          : await compute(_parseCatalogItemsInBackground, cachedJson);
      final status = await OfflineImageStore.getStatus();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _status = status;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _synchronize() async {
    if (_syncing || _catalog.isEmpty) return;
    final cancellation = OfflineImageSyncCancellation();
    _cancellation = cancellation;

    setState(() {
      _syncing = true;
      _processed = 0;
      _total = _catalog.where((item) => item.jpgExists).length;
      _available = 0;
      _failed = 0;
    });

    final result = await OfflineImageStore.synchronize(
      _catalog,
      cancellation: cancellation,
      onProgress: (processed, total, available, failed) {
        if (!mounted) return;
        setState(() {
          _processed = processed;
          _total = total;
          _available = available;
          _failed = failed;
        });
      },
    );
    final status = await OfflineImageStore.getStatus();
    if (!mounted) return;

    setState(() {
      _status = status;
      _syncing = false;
      _cancellation = null;
    });

    if (!result.cancelled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isEnglish
                ? '${result.available} images are available offline.'
                : '${result.available} Bilder sind offline verfügbar.',
          ),
        ),
      );
    }
  }

  void _cancelSync() {
    _cancellation?.cancel();
    if (mounted) setState(() {});
  }

  Future<void> _clearImages() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('Offline-Bilder löschen?', 'Delete offline images?')),
        content: Text(
          tr(
            'Alle verkleinerten Bilder werden vom Gerät entfernt. Die Bilder auf dem Server bleiben unverändert.',
            'All reduced images will be removed from the device. Images on the server remain unchanged.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(tr('Abbrechen', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(tr('Löschen', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await OfflineImageStore.clear();
    final status = await OfflineImageStore.getStatus();
    if (mounted) setState(() => _status = status);
  }

  String get _lastUpdatedText {
    final value = _status.lastUpdated;
    if (value == null) return tr('Noch nie', 'Never');
    final date = MaterialLocalizations.of(context).formatMediumDate(value);
    final time = TimeOfDay.fromDateTime(value).format(context);
    return '$date · $time';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total <= 0 ? null : _processed / _total;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: Text(tr('Offline-Bilder', 'Offline images'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _SettingsSection(
                  title: tr('STATUS', 'STATUS'),
                  children: [
                    _SettingsTile(
                      icon: Icons.photo_library_outlined,
                      title: tr('Gespeicherte Bilder', 'Saved images'),
                      value: '${_status.imageCount}',
                    ),
                    const _SettingsDivider(),
                    _SettingsTile(
                      icon: Icons.sd_storage_outlined,
                      title: tr('Speicherbedarf', 'Storage used'),
                      value: _formatStorageSize(_status.totalBytes),
                    ),
                    const _SettingsDivider(),
                    _SettingsTile(
                      icon: Icons.update_outlined,
                      title: tr('Letzte Aktualisierung', 'Last updated'),
                      value: _lastUpdatedText,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF2FF),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.info_outline, color: Color(0xFF245B9E)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          tr(
                            'Die Offline-Bilder werden auf 60 % verkleinert und geschützt in der App gespeichert. Bei Internetempfang lädt ATool weiterhin das aktuelle Bild direkt vom Server.',
                            'Offline images are reduced to 60% and stored privately inside the app. When internet access is available, ATool still loads the current image directly from the server.',
                          ),
                          style: const TextStyle(height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_syncing) ...[
                  const SizedBox(height: 22),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 10),
                  Text(
                    isEnglish
                        ? '$_processed of $_total · $_available saved · $_failed failed'
                        : '$_processed von $_total · $_available gespeichert · $_failed fehlgeschlagen',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _cancellation?.isCancelled == true
                        ? null
                        : _cancelSync,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(
                      _cancellation?.isCancelled == true
                          ? tr('Wird abgebrochen…', 'Canceling…')
                          : tr('Abbrechen', 'Cancel'),
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: _catalog.isEmpty ? null : _synchronize,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(
                      _status.imageCount == 0
                          ? tr(
                              'Offline-Bilder herunterladen',
                              'Download offline images',
                            )
                          : tr(
                              'Fehlende Bilder ergänzen',
                              'Download missing images',
                            ),
                    ),
                  ),
                  if (_status.imageCount > 0) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _clearImages,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(
                        tr('Offline-Bilder löschen', 'Delete offline images'),
                      ),
                    ),
                  ],
                  if (_catalog.isEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      tr(
                        'Der Katalog ist noch nicht verfügbar. Öffne zuerst die Artikelsuche mit einer Internetverbindung.',
                        'The catalog is not available yet. Open the item search with an internet connection first.',
                      ),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                ],
              ],
            ),
    );
  }
}

class _DxfSettingsPage extends StatefulWidget {
  final DxfLayerSettings initialSettings;
  final _DxfLayerSettingsValidator validate;

  const _DxfSettingsPage({
    required this.initialSettings,
    required this.validate,
  });

  @override
  State<_DxfSettingsPage> createState() => _DxfSettingsPageState();
}

class _DxfSettingsPageState extends State<_DxfSettingsPage> {
  late DxfLayerSettings _settings = widget.initialSettings;

  Future<void> _setEnabled(bool enabled) async {
    final settings = _settings.copyWith(enabled: enabled);
    await DxfLayerPrefs.setSettings(settings);
    if (mounted) setState(() => _settings = settings);
  }

  Future<void> _edit() async {
    final settings = await showDialog<DxfLayerSettings>(
      context: context,
      builder: (_) => _DxfLayerSettingsDialog(
        initialSettings: _settings,
        validate: widget.validate,
      ),
    );
    if (settings == null) return;

    await DxfLayerPrefs.setSettings(settings);
    if (!mounted) return;
    setState(() => _settings = settings);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('DXF-Layer gespeichert.', 'DXF layers saved.')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: Text(tr('DXF-Layer', 'DXF layers'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _SettingsSection(
            title: tr('VERARBEITUNG', 'PROCESSING'),
            children: [
              SwitchListTile(
                value: _settings.enabled,
                onChanged: _setEnabled,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                secondary: const Icon(Icons.auto_fix_high_outlined),
                title: Text(
                  tr(
                    'Layer automatisch anpassen',
                    'Adjust layers automatically',
                  ),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  tr(
                    'Beim Download wird eine angepasste DXF-Datei erzeugt.',
                    'A customized DXF file is created during download.',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          _SettingsSection(
            title: tr('EINBAUARTEN', 'INSTALLATION TYPES'),
            children: const [_DxfInstallationPreview()],
          ),
          const SizedBox(height: 22),
          _SettingsSection(
            title: tr('LAYERZUORDNUNG', 'LAYER MAPPING'),
            children: [
              _SettingsTile(
                iconWidget: const _DxfCutIcon(_DxfCutIconType.flaechenbuendig),
                title: tr('Flächenbündig (aussen)', 'Flush-mounted (outside)'),
                subtitle:
                    '${_settings.falzLayer} · ${_dxfAciColorName(_settings.falzColor)}',
              ),
              const _SettingsDivider(),
              _SettingsTile(
                iconWidget: const _DxfCutIcon(_DxfCutIconType.flaechenbuendig),
                title: tr('Flächenbündig (innen)', 'Flush-mounted (inside)'),
                subtitle:
                    '${_settings.gesaegtLayer} · ${_dxfAciColorName(_settings.gesaegtColor)}',
              ),
              const _SettingsDivider(),
              _SettingsTile(
                iconWidget: const _DxfCutIcon(_DxfCutIconType.auflage),
                title: tr('Auflage', 'Support'),
                subtitle:
                    '${_settings.auflageLayer} · ${_dxfAciColorName(_settings.auflageColor)}',
              ),
              const _SettingsDivider(),
              _SettingsTile(
                iconWidget: const _DxfCutIcon(_DxfCutIconType.unterbau),
                title: tr('Unterbau', 'Substructure'),
                subtitle:
                    '${_settings.unterbauLayer} · ${_dxfAciColorName(_settings.unterbauColor)}',
              ),
              const _SettingsDivider(),
              _SettingsTile(
                icon: Icons.radio_button_unchecked,
                title: tr('Bohrungen', 'Drill holes'),
                subtitle:
                    '${_settings.bohrungLayer} · ${_dxfAciColorName(_settings.bohrungColor)}',
              ),
              const _SettingsDivider(),
              _SettingsTile(
                icon: Icons.architecture_outlined,
                title: tr('Konstruktion', 'Construction'),
                subtitle:
                    '${_settings.konstruktionLayer} · ${_dxfAciColorName(_settings.konstruktionColor)}',
              ),
            ],
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _edit,
            icon: const Icon(Icons.edit_outlined),
            label: Text(tr('Layer bearbeiten', 'Edit layers')),
          ),
        ],
      ),
    );
  }
}

class _AccountLicensePage extends StatelessWidget {
  final Map<String, dynamic>? data;
  final String deviceUuid;
  final DeviceMeta? deviceMeta;

  const _AccountLicensePage({
    required this.data,
    required this.deviceUuid,
    required this.deviceMeta,
  });

  @override
  Widget build(BuildContext context) {
    final firm = data?['firm'] as Map<String, dynamic>?;
    final user = data?['user'] as Map<String, dynamic>?;
    final device = data?['device'] as Map<String, dynamic>?;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: Text(tr('Benutzer & Lizenz', 'User & license'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _InfoCard(
            title: tr('Benutzer', 'User'),
            icon: Icons.person_outline,
            children: [
              _InfoRow(
                label: tr('Name', 'Name'),
                value: '${user?['name'] ?? ''}',
              ),
              _InfoRow(label: 'E-Mail', value: '${user?['email'] ?? ''}'),
              _InfoRow(
                label: tr('Rolle', 'Role'),
                value: '${user?['role'] ?? ''}',
              ),
            ],
          ),
          _InfoCard(
            title: tr('Firma & Lizenz', 'Company & license'),
            icon: Icons.business_outlined,
            children: [
              _InfoRow(
                label: tr('Firma', 'Company'),
                value: '${firm?['name'] ?? ''}',
              ),
              _StatusRow(
                label: tr('Status', 'Status'),
                value: '${firm?['status'] ?? ''}',
              ),
              _InfoRow(
                label: tr('Max Geräte', 'Max. devices'),
                value: '${firm?['max_devices'] ?? ''}',
              ),
              _InfoRow(
                label: tr('Lizenz bis', 'License until'),
                value: '${firm?['license_end'] ?? ''}',
              ),
              _InfoRow(
                label: tr('Tage übrig', 'Days remaining'),
                value: '${firm?['days_left'] ?? ''}',
              ),
            ],
          ),
          _InfoCard(
            title: tr('Gerät', 'Device'),
            icon: Icons.devices_outlined,
            children: [
              _InfoRow(label: tr('Lokale ID', 'Local ID'), value: deviceUuid),
              _InfoRow(
                label: tr('Gerät', 'Device'),
                value: deviceMeta?.deviceName ?? '',
              ),
              _InfoRow(
                label: tr('Betriebssystem', 'Operating system'),
                value: deviceMeta?.osVersion ?? '',
              ),
              _InfoRow(
                label: tr('App-Version', 'App version'),
                value: deviceMeta?.appVersion ?? '',
              ),
              _StatusRow(
                label: tr('Gerätestatus', 'Device status'),
                value: '${device?['status'] ?? ''}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LegalSettingsPage extends StatelessWidget {
  final VoidCallback onShowUsageInformation;
  final Future<void> Function() onOpenPrivacyPolicy;

  const _LegalSettingsPage({
    required this.onShowUsageInformation,
    required this.onOpenPrivacyPolicy,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(tr('Datenschutz & Nutzung', 'Privacy & usage')),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            tr(
              'Hier findest du Hinweise zur Nutzung von ATool und die aktuelle Datenschutzerklärung.',
              'Find information about using ATool and the current privacy policy here.',
            ),
            style: const TextStyle(color: Colors.black54, height: 1.45),
          ),
          const SizedBox(height: 20),
          _SettingsSection(
            title: tr('INFORMATIONEN', 'INFORMATION'),
            children: [
              _SettingsTile(
                icon: Icons.description_outlined,
                title: tr('Hinweise zur Nutzung', 'Usage information'),
                subtitle: tr(
                  'Datenqualität, OCR und betriebliche Nutzung',
                  'Data quality, OCR, and business use',
                ),
                onTap: onShowUsageInformation,
              ),
              const _SettingsDivider(),
              _SettingsTile(
                icon: Icons.privacy_tip_outlined,
                title: tr('Datenschutzerklärung', 'Privacy policy'),
                subtitle: tr(
                  'Öffnet die aktuelle Version im Browser',
                  'Opens the current version in your browser',
                ),
                onTap: () => unawaited(onOpenPrivacyPolicy()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class AppHelpPage extends StatelessWidget {
  const AppHelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(title: Text(tr('ATool Hilfe', 'ATool help'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            tr('Die App-Oberfläche erklärt', 'Understanding the app'),
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            tr(
              'ATool hilft dir, Artikelnummern auf Etiketten zu erkennen, passende Ausschnitte zu finden und die zugehörigen Dateien zu öffnen oder herunterzuladen.',
              'ATool helps you recognize item numbers on labels, find matching cut-outs, and open or download the related files.',
            ),
            style: const TextStyle(
              color: Colors.black54,
              fontSize: 15,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 20),
          _HelpSection(
            icon: Icons.search,
            title: tr('Artikelnummer suchen', 'Search for an item number'),
            text: tr(
              'Gib oben mindestens vier Zeichen der Artikelnummer ein. Die Treffer erscheinen automatisch. Mit der Suchtaste der Tastatur kannst du die Suche ebenfalls direkt starten.',
              'Enter at least four characters of the item number at the top. Results appear automatically. You can also start the search with the keyboard search button.',
            ),
          ),
          _HelpSection(
            icon: Icons.camera_alt_outlined,
            title: tr('Etikett mit OCR erfassen', 'Scan a label with OCR'),
            text: tr(
              'Tippe auf das Kamera-Symbol und fotografiere das Etikett möglichst gerade und bildfüllend. Alternativ kannst du ein vorhandenes Bild aus der Galerie wählen.',
              'Tap the camera icon and photograph the label as straight and full-frame as possible. You can also select an existing image from the gallery.',
            ),
          ),
          _HelpSection(
            icon: Icons.stop_circle_outlined,
            title: tr(
              'OCR abbrechen oder korrigieren',
              'Cancel or correct OCR',
            ),
            text: tr(
              'Mit „OCR abbrechen“ stoppst du die automatische Suche sofort. Danach kannst du die Artikelnummer selbst eingeben oder einen bereits erkannten OCR-Begriff antippen.',
              'Use “Cancel OCR” to stop the automatic search immediately. You can then enter the item number yourself or tap an OCR term that has already been recognized.',
            ),
          ),
          _HelpSection(
            icon: Icons.list_alt_outlined,
            title: tr('Treffer verstehen', 'Understanding results'),
            text: tr(
              'Ein grüner Hinweis bedeutet, dass ATool passende Artikel gefunden hat. In jeder Trefferkarte siehst du Hersteller, Typ und Dateiname.',
              'A green message means that ATool found matching items. Each result card shows the manufacturer, type, and file name.',
            ),
          ),
          _HelpSection(
            icon: Icons.visibility_outlined,
            title: tr('Ansehen', 'View'),
            text: tr(
              'Öffnet die Vorschau des Ausschnitts. Mit Doppeltippen oder zwei Fingern kannst du das Bild vergrößern.',
              'Opens a preview of the cut-out. Double-tap or use two fingers to zoom the image.',
            ),
          ),
          _HelpSection(
            icon: Icons.download_outlined,
            title: tr('Download und PDF-Suche', 'Download and PDF search'),
            text: tr(
              '„Download“ teilt oder speichert die DXF-Datei. „PDF suchen“ öffnet eine Websuche nach passenden technischen Unterlagen.',
              '“Download” shares or saves the DXF file. “Search PDF” opens a web search for matching technical documents.',
            ),
          ),
          _HelpSection(
            icon: Icons.settings_outlined,
            title: tr('Einstellungen', 'Settings'),
            text: tr(
              'Über das Zahnrad änderst du Sprache, Download-Ziel und DXF-Layer. Im Bereich „Info & Lizenz“ findest du Geräte-, Firmen- und Lizenzinformationen.',
              'Use the gear icon to change the language, download destination, and DXF layers. “Info & license” contains device, company, and license details.',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check),
            label: Text(tr('Verstanden', 'Got it')),
          ),
        ],
      ),
    );
  }
}

class _HelpSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const _HelpSection({
    required this.icon,
    required this.title,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2C),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    text,
                    style: const TextStyle(color: Colors.black87, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ImageViewerPage extends StatefulWidget {
  final String imageUrl;
  final String filename;
  final String? localImagePath;

  const ImageViewerPage({
    super.key,
    required this.imageUrl,
    required this.filename,
    this.localImagePath,
  });

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  final TransformationController _transformationController =
      TransformationController();
  TapDownDetails? _doubleTapDetails;
  bool _isZoomed = false;

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapDetails = details;
  }

  void _handleDoubleTap() {
    final position = _doubleTapDetails?.localPosition ?? Offset.zero;

    if (_isZoomed) {
      _transformationController.value = Matrix4.identity();
      setState(() {
        _isZoomed = false;
      });
      return;
    }

    const scale = 2.5;
    _transformationController.value = Matrix4.identity()
      ..translateByDouble(
        -position.dx * (scale - 1),
        -position.dy * (scale - 1),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1);
    setState(() {
      _isZoomed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.filename)),
      body: GestureDetector(
        onDoubleTapDown: _handleDoubleTapDown,
        onDoubleTap: _handleDoubleTap,
        child: InteractiveViewer(
          transformationController: _transformationController,
          panEnabled: true,
          scaleEnabled: true,
          constrained: true,
          boundaryMargin: const EdgeInsets.all(120),
          minScale: 0.8,
          maxScale: 6,
          child: Center(
            child: Image.network(
              widget.imageUrl,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) {
                final localPath = widget.localImagePath;
                if (localPath != null && localPath.isNotEmpty) {
                  return Image.file(
                    File(localPath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => _imageError(),
                  );
                }
                return _imageError();
              },
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                final localPath = widget.localImagePath;
                if (localPath != null && localPath.isNotEmpty) {
                  return Image.file(
                    File(localPath),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) =>
                        const Center(child: CircularProgressIndicator()),
                  );
                }
                return const Center(child: CircularProgressIndicator());
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _imageError() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        tr(
          'Vorschaubild konnte nicht geladen werden.',
          'Could not load the preview image.',
        ),
        style: const TextStyle(color: Colors.red),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _HeaderActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool smallIcon;

  const _HeaderActionButton({
    required this.icon,
    required this.onTap,
    this.smallIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: smallIcon ? 20 : 28, color: Colors.black),
        ),
      ),
    );
  }
}

class _FooterLinkRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback onTap;

  const _FooterLinkRow({
    required this.icon,
    required this.text,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.white,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

typedef _DxfLayerSettingsValidator =
    String? Function(
      String falzLayer,
      String gesaegtLayer,
      String auflageLayer,
      String unterbauLayer,
      String bohrungLayer,
      String konstruktionLayer,
      int? falzColor,
      int? gesaegtColor,
      int? auflageColor,
      int? unterbauColor,
      int? bohrungColor,
      int? konstruktionColor,
    );

class _DxfLayerSettingsDialog extends StatefulWidget {
  final DxfLayerSettings initialSettings;
  final _DxfLayerSettingsValidator validate;

  const _DxfLayerSettingsDialog({
    required this.initialSettings,
    required this.validate,
  });

  @override
  State<_DxfLayerSettingsDialog> createState() =>
      _DxfLayerSettingsDialogState();
}

class _DxfLayerSettingsDialogState extends State<_DxfLayerSettingsDialog> {
  late final TextEditingController _falzController;
  late final TextEditingController _gesaegtController;
  late final TextEditingController _auflageController;
  late final TextEditingController _unterbauController;
  late final TextEditingController _bohrungController;
  late final TextEditingController _konstruktionController;
  late int _falzColor;
  late int _gesaegtColor;
  late int _auflageColor;
  late int _unterbauColor;
  late int _bohrungColor;
  late int _konstruktionColor;

  String? _errorText;

  @override
  void initState() {
    super.initState();

    final settings = widget.initialSettings;
    _falzController = TextEditingController(text: settings.falzLayer);
    _gesaegtController = TextEditingController(text: settings.gesaegtLayer);
    _auflageController = TextEditingController(text: settings.auflageLayer);
    _unterbauController = TextEditingController(text: settings.unterbauLayer);
    _bohrungController = TextEditingController(text: settings.bohrungLayer);
    _konstruktionController = TextEditingController(
      text: settings.konstruktionLayer,
    );
    _falzColor = settings.falzColor;
    _gesaegtColor = settings.gesaegtColor;
    _auflageColor = settings.auflageColor;
    _unterbauColor = settings.unterbauColor;
    _bohrungColor = settings.bohrungColor;
    _konstruktionColor = settings.konstruktionColor;
  }

  @override
  void dispose() {
    _falzController.dispose();
    _gesaegtController.dispose();
    _auflageController.dispose();
    _unterbauController.dispose();
    _bohrungController.dispose();
    _konstruktionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('DXF-Layer', 'DXF layers')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _inputRow(
                label: tr('AUSSCHNITT Falz', 'CUT-OUT rebate'),
                layerController: _falzController,
                selectedColor: _falzColor,
                onColorSelected: (color) => setState(() {
                  _falzColor = color;
                }),
              ),
              const SizedBox(height: 12),
              _inputRow(
                label: tr('AUSSCHNITT gesägt', 'CUT-OUT saw cut'),
                layerController: _gesaegtController,
                selectedColor: _gesaegtColor,
                onColorSelected: (color) => setState(() {
                  _gesaegtColor = color;
                }),
              ),
              const SizedBox(height: 12),
              _inputRow(
                label: tr('Auflage', 'Support'),
                layerController: _auflageController,
                selectedColor: _auflageColor,
                onColorSelected: (color) => setState(() {
                  _auflageColor = color;
                }),
              ),
              const SizedBox(height: 12),
              _inputRow(
                label: tr('Unterbau', 'Substructure'),
                layerController: _unterbauController,
                selectedColor: _unterbauColor,
                onColorSelected: (color) => setState(() {
                  _unterbauColor = color;
                }),
              ),
              const SizedBox(height: 12),
              _inputRow(
                label: tr('Bohrungen', 'Drill holes'),
                layerController: _bohrungController,
                selectedColor: _bohrungColor,
                onColorSelected: (color) => setState(() {
                  _bohrungColor = color;
                }),
              ),
              const SizedBox(height: 12),
              _inputRow(
                label: tr('Konstruktion', 'Construction'),
                layerController: _konstruktionController,
                selectedColor: _konstruktionColor,
                onColorSelected: (color) => setState(() {
                  _konstruktionColor = color;
                }),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _errorText!,
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('Abbrechen', 'Cancel')),
        ),
        ElevatedButton(onPressed: _save, child: Text(tr('Speichern', 'Save'))),
      ],
    );
  }

  Widget _inputRow({
    required String label,
    required TextEditingController layerController,
    required int selectedColor,
    required ValueChanged<int> onColorSelected,
  }) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: TextField(
            controller: layerController,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 132,
          child: _DxfColorSelectButton(
            selectedColor: selectedColor,
            onSelected: onColorSelected,
          ),
        ),
      ],
    );
  }

  void _save() {
    final falzLayer = _falzController.text.trim();
    final gesaegtLayer = _gesaegtController.text.trim();
    final auflageLayer = _auflageController.text.trim();
    final unterbauLayer = _unterbauController.text.trim();
    final bohrungLayer = _bohrungController.text.trim();
    final konstruktionLayer = _konstruktionController.text.trim();
    final validationError = widget.validate(
      falzLayer,
      gesaegtLayer,
      auflageLayer,
      unterbauLayer,
      bohrungLayer,
      konstruktionLayer,
      _falzColor,
      _gesaegtColor,
      _auflageColor,
      _unterbauColor,
      _bohrungColor,
      _konstruktionColor,
    );

    if (validationError != null) {
      setState(() {
        _errorText = validationError;
      });
      return;
    }

    Navigator.of(context).pop(
      DxfLayerSettings(
        enabled: widget.initialSettings.enabled,
        falzLayer: falzLayer,
        gesaegtLayer: gesaegtLayer,
        auflageLayer: auflageLayer,
        unterbauLayer: unterbauLayer,
        bohrungLayer: bohrungLayer,
        konstruktionLayer: konstruktionLayer,
        falzColor: _falzColor,
        gesaegtColor: _gesaegtColor,
        auflageColor: _auflageColor,
        unterbauColor: _unterbauColor,
        bohrungColor: _bohrungColor,
        konstruktionColor: _konstruktionColor,
      ),
    );
  }
}

class _DxfColorSelectButton extends StatelessWidget {
  final int selectedColor;
  final ValueChanged<int> onSelected;

  const _DxfColorSelectButton({
    required this.selectedColor,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final color = _dxfAciFlutterColor(selectedColor);

    return OutlinedButton(
      onPressed: () async {
        final result = await showDialog<int>(
          context: context,
          builder: (_) => _DxfColorPickerDialog(selectedColor: selectedColor),
        );

        if (result != null) onSelected(result);
      },
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.black26),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _dxfAciColorName(selectedColor),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _DxfColorPickerDialog extends StatelessWidget {
  final int selectedColor;

  const _DxfColorPickerDialog({required this.selectedColor});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Farbe wählen', 'Select color')),
      content: SizedBox(
        width: 380,
        child: GridView.builder(
          shrinkWrap: true,
          itemCount: _dxfAciColorOptions.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.35,
          ),
          itemBuilder: (context, index) {
            final option = _dxfAciColorOptions[index];
            final selected = option.aci == selectedColor;
            return Tooltip(
              message: _localizedDxfColorName(option.name),
              child: InkWell(
                onTap: () => Navigator.of(context).pop(option.aci),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    color: option.color,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: selected ? Colors.black : Colors.black26,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _dxfReadableLabelBackground(option.color),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _localizedDxfColorName(option.name),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _dxfReadableLabelColor(option.color),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(tr('Abbrechen', 'Cancel')),
        ),
      ],
    );
  }
}

class _DxfAciColorOption {
  final int aci;
  final String name;
  final Color color;

  const _DxfAciColorOption({
    required this.aci,
    required this.name,
    required this.color,
  });
}

const List<_DxfAciColorOption> _dxfAciColorOptions = [
  _DxfAciColorOption(aci: 1, name: 'Rot', color: Color(0xFFE53935)),
  _DxfAciColorOption(aci: 2, name: 'Gelb', color: Color(0xFFFFD600)),
  _DxfAciColorOption(aci: 3, name: 'Grün', color: Color(0xFF43A047)),
  _DxfAciColorOption(aci: 4, name: 'Cyan', color: Color(0xFF00ACC1)),
  _DxfAciColorOption(aci: 5, name: 'Blau', color: Color(0xFF1E5BFF)),
  _DxfAciColorOption(aci: 6, name: 'Magenta', color: Color(0xFFD81B60)),
  _DxfAciColorOption(aci: 7, name: 'Weiß', color: Color(0xFFFFFFFF)),
  _DxfAciColorOption(aci: 8, name: 'Grau', color: Color(0xFF777777)),
  _DxfAciColorOption(aci: 9, name: 'Hellgrau', color: Color(0xFFC8C8C8)),
  _DxfAciColorOption(aci: 30, name: 'Orange', color: Color(0xFFFF8F00)),
  _DxfAciColorOption(aci: 140, name: 'Violett', color: Color(0xFF8E24AA)),
  _DxfAciColorOption(aci: 170, name: 'Braun', color: Color(0xFF8D6E63)),
];

String _dxfAciColorName(int aci) {
  for (final option in _dxfAciColorOptions) {
    if (option.aci == aci) return _localizedDxfColorName(option.name);
  }

  return tr('Farbe', 'Color');
}

String _localizedDxfColorName(String name) {
  if (!isEnglish) return name;

  return switch (name) {
    'Rot' => 'Red',
    'Gelb' => 'Yellow',
    'Grün' => 'Green',
    'Blau' => 'Blue',
    'Weiß' => 'White',
    'Grau' => 'Gray',
    'Hellgrau' => 'Light gray',
    'Violett' => 'Violet',
    'Braun' => 'Brown',
    _ => name,
  };
}

Color _dxfAciFlutterColor(int aci) {
  for (final option in _dxfAciColorOptions) {
    if (option.aci == aci) return option.color;
  }

  return const Color(0xFF777777);
}

Color _dxfReadableLabelBackground(Color color) {
  return _dxfColorIsLight(color) ? Colors.black54 : Colors.white70;
}

Color _dxfReadableLabelColor(Color color) {
  return _dxfColorIsLight(color) ? Colors.white : Colors.black87;
}

bool _dxfColorIsLight(Color color) {
  return color.computeLuminance() > 0.58;
}

class _InfoCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _InfoCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE4E4E4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.black54,
              ),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatusRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final color = statusColor(value);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.black54,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Text(
              value,
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}
