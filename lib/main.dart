import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';
import 'package:url_launcher/url_launcher.dart';

import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

void main() {
  runApp(const AToolApp());
}

class AToolApp extends StatelessWidget {
  const AToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ATool',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      home: const SplashPage(),
    );
  }
}

class AppConfig {
  static const String baseUrl = 'https://adler-aufmasse.de/licensing/api';
  static const String catalogUrl =
      'https://adler-aufmasse.de/wp-json/adler/v1/catalog';
  static const String dwgListUrl =
    'https://adler-aufmasse.de/wp-json/adler/v1/dwg-list';    
  static const String logUrl =
      'https://adler-aufmasse.de/wp-json/adler/v1/log-search';
  static const String mediaBaseUrl =
      'https://adler-aufmasse.de/wp-content/Adler/';
  static const String ocrUrl =
      'https://adler-aufmasse.de/wp-json/adler/v1/ocr';    
}

class AppStorage {
  static const FlutterSecureStorage storage = FlutterSecureStorage();
  static const Uuid uuid = Uuid();

  static Future<String> getOrCreateDeviceUuid() async {
    final existing = await storage.read(key: 'device_uuid');
    if (existing != null && existing.isNotEmpty) return existing;

    final newUuid = uuid.v4();
    await storage.write(key: 'device_uuid', value: newUuid);
    return newUuid;
  }

  static Future<String?> getAccessToken() async {
    return storage.read(key: 'access_token');
  }

  static Future<String?> getRefreshToken() async {
    return storage.read(key: 'refresh_token');
  }

  static Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await storage.write(key: 'access_token', value: accessToken);
    await storage.write(key: 'refresh_token', value: refreshToken);
  }

  static Future<void> updateAccessToken(String accessToken) async {
    await storage.write(key: 'access_token', value: accessToken);
  }

  static Future<void> clearTokens() async {
    await storage.delete(key: 'access_token');
    await storage.delete(key: 'refresh_token');
  }
}

class DownloadPrefs {
  static const String downloadDirKey = 'download_dir';

  static Future<String?> getDownloadDir() async {
    final prefs = SharedPreferencesAsync();
    return await prefs.getString(downloadDirKey);
  }

  static Future<void> setDownloadDir(String path) async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString(downloadDirKey, path);
  }

  static Future<void> clearDownloadDir() async {
    final prefs = SharedPreferencesAsync();
    await prefs.remove(downloadDirKey);
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

class CatalogSearchEntry {
  final CatalogItem item;
  final String searchText;
  final String compactText;
  final List<String> fieldTexts;
  final List<String> fieldCompacts;
  final Set<String> tokens;

  const CatalogSearchEntry({
    required this.item,
    required this.searchText,
    required this.compactText,
    required this.fieldTexts,
    required this.fieldCompacts,
    required this.tokens,
  });
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
    String deviceName = 'Unbekanntes Gerät';
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
  static Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final deviceUuid = await AppStorage.getOrCreateDeviceUuid();
    final meta = await DeviceMetaService.load();

    final uri = Uri.parse('${AppConfig.baseUrl}/login.php');

    final response = await http.post(
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

    final response = await http.post(
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

  static Future<Map<String, dynamic>> refreshAccessToken() async {
    final refreshToken = await AppStorage.getRefreshToken();

    if (refreshToken == null || refreshToken.isEmpty) {
      return {'success': false, 'message': 'Kein Refresh Token vorhanden'};
    }

    final uri = Uri.parse('${AppConfig.baseUrl}/refresh-token.php');

    final response = await http.post(
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

    final response = await http.get(
      uri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    final data = Map<String, dynamic>.from(jsonDecode(response.body));

    if (data['success'] == true) return data;

    final message = (data['message'] ?? '').toString().toLowerCase();
    final tokenProblem = message.contains('abgelaufen') ||
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

        final retryResponse = await http.get(
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

        await http.post(
          uri,
          headers: {'Authorization': 'Bearer $accessToken'},
        );
      }
    } catch (_) {}

    await AppStorage.clearTokens();
  }
}

String mapLoginErrorMessage(Map<String, dynamic> data) {
  final message = (data['message'] ?? '').toString();

  if (message.contains('Passwort ist falsch')) {
    return 'Das Passwort ist falsch.';
  }
  if (message.contains('Benutzer nicht gefunden')) {
    return 'Dieser Benutzer wurde nicht gefunden.';
  }
  if (message.contains('Benutzer ist gesperrt')) {
    return 'Dieser Benutzer ist gesperrt.';
  }
  if (message.contains('Firma ist nicht aktiv')) {
    return 'Die Firma ist aktuell nicht aktiv.';
  }
  if (message.contains('Lizenz ist abgelaufen')) {
    return 'Die Lizenz ist abgelaufen.';
  }
  if (message.contains('Maximale Anzahl aktiver Geräte erreicht')) {
    return 'Die maximale Anzahl aktiver Geräte wurde erreicht.';
  }
  if (message.contains('Gerät ist nicht aktiv')) {
    return 'Dieses Gerät ist nicht aktiv.';
  }

  return message.isNotEmpty ? message : 'Unbekannter Login-Fehler.';
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
    await AppStorage.getOrCreateDeviceUuid();

    final accessToken = await AppStorage.getAccessToken();
    final refreshToken = await AppStorage.getRefreshToken();

    if (!mounted) return;

    if ((accessToken != null && accessToken.isNotEmpty) ||
        (refreshToken != null && refreshToken.isNotEmpty)) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainSearchPage()),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLoading = false;
  String _errorMessage = '';
  String _successMessage = '';
  String _deviceUuid = '';

  @override
  void initState() {
    super.initState();
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
        _errorMessage =
            'Verbindung fehlgeschlagen. Bitte Internet und Server prüfen.';
      });
    } finally {
      if (!mounted) {
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
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
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
                            const Text(
                              'Login für lizenzierte Firmenkunden',
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
                                prefixIcon:
                                    const Icon(Icons.email_outlined),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _passwordController,
                              obscureText: true,
                              onSubmitted: (_) => _isLoading ? null : _login(),
                              decoration: InputDecoration(
                                labelText: 'Passwort',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                prefixIcon:
                                    const Icon(Icons.lock_outline),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: SelectableText(
                                'Geräte-ID: ${_deviceUuid.isEmpty ? "wird geladen..." : _deviceUuid}',
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
                                    color:
                                        Colors.green.withValues(alpha: 0.25),
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
                                      ? 'Anmeldung läuft...'
                                      : 'Einloggen',
                                ),
                                style: ElevatedButton.styleFrom(
                                  shape: RoundedRectangleBorder(
                                    borderRadius:
                                        BorderRadius.circular(14),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: _isLoading
                                  ? null
                                  : () async {
                                      final result =
                                          await Navigator.of(context)
                                              .push<String>(
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
                                          _successMessage =
                                              'Testzugang erstellt. Bitte jetzt mit deiner E-Mail einloggen.';
                                        });
                                      }
                                    },
                              child:
                                  const Text('10 Tage testen / Registrieren'),
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
          const SnackBar(
            content: Text('Testzugang erfolgreich erstellt.'),
          ),
        );

        Navigator.of(context).pop(_emailController.text.trim());
      } else {
        setState(() {
          _message = (data['message'] ?? 'Registrierung fehlgeschlagen.').toString();
        });
      }
    } catch (_) {
      setState(() {
        _message = 'Registrierung fehlgeschlagen. Bitte Serververbindung prüfen.';
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
      appBar: AppBar(
        title: const Text('10 Tage testen'),
      ),
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
                    const Text(
                      'Testzugang registrieren',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Erstelle einen Firmen-Testzugang für 10 Tage.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _companyController,
                      decoration: InputDecoration(
                        labelText: 'Firmenname',
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
                        labelText: 'Ansprechpartner',
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
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: 'Passwort',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        prefixIcon: const Icon(Icons.lock_outline),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _phoneController,
                      decoration: InputDecoration(
                        labelText: 'Telefon (optional)',
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
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.app_registration),
                        label: Text(
                          _isLoading
                              ? 'Registrierung läuft...'
                              : 'Testzugang erstellen',
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

  const OcrBoxCandidate({
    required this.text,
    required this.area,
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

class _MainSearchPageState extends State<MainSearchPage> {
  static const int minSearchLen = 2;

  bool _pageLoading = true;
  bool _countLoading = true;
  bool _searchLoading = false;
  bool _showOcrSuggestions = false;

  String _message = '';
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  bool _ignoreSearchControllerChange = false;

  List<CatalogItem> _catalog = [];
  List<CatalogSearchEntry> _catalogSearchIndex = [];
  List<CatalogItem> _results = [];
  String _activeHighlightTerm = '';
  List<String> _ocrBoxTexts = [];
  int? _totalCount;
  int? _dwgDisplayCount;

  @override
  void initState() {
    super.initState();
    _initPage();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
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
  await Future.wait([
    _loadIndex(),
    _loadDwgDisplayCount(),
  ]);
}

void _rebuildCatalogSearchIndex() {
  _catalogSearchIndex = _catalog.map((item) {
    final rawFields = <String>[
      item.basename,
      item.id,
      item.dwgPath ?? '',
      item.dxfPath ?? '',
      item.jpgPath ?? '',
      // bewusst OHNE item.manufacturer
      // bewusst OHNE item.type
    ].where((e) => e.trim().isNotEmpty).toList();

    final fieldTexts = rawFields
        .map(_normalizeForSearch)
        .where((e) => e.trim().isNotEmpty)
        .toList();

    final fieldCompacts = fieldTexts
        .map((e) => e.replaceAll(RegExp(r'[^a-z0-9]'), ''))
        .where((e) => e.length >= minSearchLen)
        .toList();

    final searchText = fieldTexts.join(' ');
    final compactText = searchText.replaceAll(RegExp(r'[^a-z0-9]'), '');

    final tokens = searchText
        .split(RegExp(r'[\s\-/._]+'))
        .map((e) => e.trim())
        .where((e) => e.length >= 2)
        .toSet();

    return CatalogSearchEntry(
      item: item,
      searchText: searchText,
      compactText: compactText,
      fieldTexts: fieldTexts,
      fieldCompacts: fieldCompacts,
      tokens: tokens,
    );
  }).toList();

  debugPrint('CATALOG SEARCH INDEX READY: ${_catalogSearchIndex.length}');
}

  Future<void> _loadIndex() async {
    setState(() {
      _countLoading = true;
      _pageLoading = true;
      _message = '';
    });

    try {
      final resp = await http.get(Uri.parse(AppConfig.catalogUrl));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final itemsRaw = (data['items'] as List<dynamic>? ?? []);

      final items = itemsRaw
          .whereType<Map>()
          .map((e) => CatalogItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      if (!mounted) return;

      setState(() {
        _catalog = items;
        _totalCount = items.length;
        _countLoading = false;
        _pageLoading = false;
      });

      _rebuildCatalogSearchIndex();

    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message = 'Katalog konnte nicht geladen werden.';
        _countLoading = false;
        _pageLoading = false;
      });
    }
  }

void _onSearchChanged() {
  if (_ignoreSearchControllerChange) {
    return;
  }

  _debounce?.cancel();
  final q = _searchController.text.trim();

  if (q.length < minSearchLen) {
    setState(() {
      _results = [];
      _searchLoading = false;
      _activeHighlightTerm = '';
      _message = '';
    });
    return;
  }

  _debounce = Timer(const Duration(milliseconds: 250), () {
    _handleSearchDirect(q);
  });
}

  String _safeDxfFileName(String filename) {
    final base = filename.trim().isEmpty ? 'download' : filename.trim();
    return '$base.dxf';
  }

String _normalizeForSearch(String input) {
  var s = input.toLowerCase().trim();

  const replacements = {
    'ä': 'a',
    'ö': 'o',
    'ü': 'u',
    'ß': 'ss',
  };

  replacements.forEach((key, value) {
    s = s.replaceAll(key, value);
  });

  s = s.replaceAll(RegExp(r'[^a-z0-9/_. -]'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  // einzelne Tokens behandeln, damit z. B. 00525995 -> 525995 wird
  final parts = s.split(' ').map((part) {
    // nur bei rein numerischen Tokens führende Nullen entfernen
    if (RegExp(r'^0+\d+$').hasMatch(part)) {
      return part.replaceFirst(RegExp(r'^0+'), '');
    }

    // auch für gemischte Formen wie 00-123 eher nicht anfassen
    return part;
  }).where((e) => e.isNotEmpty).toList();

  return parts.join(' ');
}

Set<String> _buildCompareVariants(String input) {
  final base = _normalizeForSearch(input);

  if (base.isEmpty) return {};

  final variants = <String>{
    base,
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

List<CatalogItem> _localSearch(String q) {
  final queryVariants = _buildCompareVariants(q);
  if (queryVariants.isEmpty) return [];

  bool matches(CatalogItem item) {
    final itemFields = <String>[
      item.manufacturer,
      item.type,
      item.basename,
      item.id,
      item.dwgPath ?? '',
      item.dxfPath ?? '',
      item.jpgPath ?? '',
    ];

    for (final field in itemFields) {
      final fieldVariants = _buildCompareVariants(field);

      for (final qv in queryVariants) {
        for (final fv in fieldVariants) {
          if (fv.contains(qv)) {
            return true;
          }
        }
      }
    }

    return false;
  }

  return _catalog.where(matches).take(50).toList();
}

List<String> _buildSearchFallbackTerms(String input) {
  final cleaned = input.trim().replaceAll(RegExp(r'\s+'), ' ');

  if (cleaned.isEmpty) return [];

  final withoutManufacturer =
      _removeManufacturerTokensFromOcrTerm(cleaned);

  final parts = (withoutManufacturer.isNotEmpty
          ? withoutManufacturer
          : cleaned)
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
            title: const Text('Kamera'),
            onTap: () => Navigator.of(context).pop(ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Galerie'),
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

  final parts = cleaned.split(' ').map((part) {
    final p = part.trim();

    // nur bei rein numerischen Teilen führende Nullen entfernen
    if (RegExp(r'^0+\d+$').hasMatch(p)) {
      final stripped = p.replaceFirst(RegExp(r'^0+'), '');
      return stripped.isEmpty ? '0' : stripped;
    }

    return p;
  }).where((e) => e.isNotEmpty).toList();

  return parts.join(' ').trim();
}

List<OcrBoxCandidate> _extractOcrBoxCandidatesSorted(RecognizedText recognizedText) {
  final candidates = <OcrBoxCandidate>[];

  for (final block in recognizedText.blocks) {
    final blockText = _cleanOcrLine(block.text);
    final blockBox = block.boundingBox;
    final blockArea = blockBox.width * blockBox.height;

    if (blockText.isNotEmpty && blockArea > 0) {
      candidates.add(OcrBoxCandidate(
        text: blockText,
        area: blockArea,
      ));
    }

    for (final line in block.lines) {
      final lineText = _cleanOcrLine(line.text);
      final lineBox = line.boundingBox;
      final lineArea = lineBox.width * lineBox.height;

      if (lineText.isNotEmpty && lineArea > 0) {
        candidates.add(OcrBoxCandidate(
          text: lineText,
          area: lineArea,
        ));
      }
    }
  }

  final deduped = <String, OcrBoxCandidate>{};

  for (final c in candidates) {
    final key = _normalizeOcrSearchTerm(c.text);
    if (key.isEmpty) continue;

    final existing = deduped[key];
    if (existing == null || c.area > existing.area) {
      deduped[key] = OcrBoxCandidate(
        text: key,
        area: c.area,
      );
    }
  }

  final sorted = deduped.values.toList()
    ..sort((a, b) => b.area.compareTo(a.area));

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

  // Zusätzlich gegen Hersteller aus dem Catalog prüfen.
  for (final item in _catalog) {
    final manufacturer = _normalizeForSearch(item.manufacturer);

    if (manufacturer.isNotEmpty && manufacturer == normalized) {
      return true;
    }
  }

  return false;
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

List<CatalogItem> _fastLocalOcrSearch(String q, {int limit = 20}) {
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
        if (fieldText.length >= minSearchLen &&
            qNorm.contains(fieldText)) {
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

  // Beispiele: EH601HFB1E, D100L, KM6023, 521841
  if (hasLetter && hasDigit && compact.length >= 4) return true;
  if (!hasLetter && hasDigit && compact.length >= 5) return true;

  return false;
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

List<String> _buildSmartOcrCandidates(
  String rawText,
  List<OcrBoxCandidate> boxes,
) {
  final candidates = <String>[];

  void addCandidate(String value) {
    final cleaned = _normalizeOcrSearchTerm(value);
    if (cleaned.length < minSearchLen) return;

    // Sehr lange Zeilen sind meist Beschreibungen, Adressen oder Liefertexte.
    // Kurze Kombinationen wie "MONO D100L" bleiben erlaubt.
    if (cleaned.length > 36) return;

    if (!candidates.contains(cleaned)) {
      candidates.add(cleaned);
    }
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
    for (final match in RegExp(r'\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+')
        .allMatches(boxText)) {
      final value = match.group(0);
      if (value != null) addCandidate(value);
    }
  }

  // Auch aus dem Gesamttext Kandidaten ziehen.
  final allText = [
    rawText,
    ...boxes.map((e) => e.text),
  ].join(' ');

  for (final match in RegExp(r'\b(?=[A-Za-z0-9]*[A-Za-z])(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{4,}\b')
      .allMatches(allText)) {
    final value = match.group(0);
    if (value != null) addCandidate(value);
  }

  for (final match in RegExp(r'\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+')
      .allMatches(allText)) {
    final value = match.group(0);
    if (value != null) addCandidate(value);
  }

  for (final match in RegExp(r'\b\d{5,}\b').allMatches(allText)) {
    final value = match.group(0);
    if (value != null) addCandidate(value);
  }

candidates.sort((a, b) {
  final formattedNumberRegex =
      RegExp(r'^\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+$');

  final aIsFormattedNumber = formattedNumberRegex.hasMatch(a);
  final bIsFormattedNumber = formattedNumberRegex.hasMatch(b);

  // Formatierte Artikelnummern wie 127.0658.064 sehr hoch priorisieren.
  if (aIsFormattedNumber != bIsFormattedNumber) {
    return aIsFormattedNumber ? -1 : 1;
  }

  final aWords = a.split(RegExp(r'\s+')).length;
  final bWords = b.split(RegExp(r'\s+')).length;

  final aStrongCount =
      _tokenizeSmartOcr(a).where(_looksLikeStrongArticleToken).length;
  final bStrongCount =
      _tokenizeSmartOcr(b).where(_looksLikeStrongArticleToken).length;

  if (aWords != bWords) return bWords.compareTo(aWords);
  if (aStrongCount != bStrongCount) {
    return bStrongCount.compareTo(aStrongCount);
  }

  return b.length.compareTo(a.length);
});

  debugPrint('SMART OCR CANDIDATES: $candidates');

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

    if (candidateCompact.length >= 5 && fieldCompact.contains(candidateCompact)) {
      score += 2500 + candidateCompact.length;
    }

    if (fieldCompact.length >= 5 && candidateCompact.contains(fieldCompact)) {
      score += 1400 + fieldCompact.length;
    }

    var matchedTokens = 0;

    for (final token in candidateTokens) {
      final tokenCompact = _compactForSmartOcr(token);
      if (tokenCompact.length < 2) continue;

      final tokenInField = fieldTokens.contains(token) ||
          fieldCompact.contains(tokenCompact);

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

List<OcrCatalogMatch> _findFastNumberOcrMatches(
  String rawText,
  List<OcrBoxCandidate> boxes,
) {
  final numberCandidates = <String>[];

void addNumber(String value) {
  final cleaned = value.trim();
  if (cleaned.length < 5) return;

  if (!numberCandidates.contains(cleaned)) {
    numberCandidates.add(cleaned);
  }

  final compact = cleaned.replaceAll(RegExp(r'[^0-9a-zA-Z]'), '');

  if (compact.length >= 5 && !numberCandidates.contains(compact)) {
    numberCandidates.add(compact);
  }

  if (compact.startsWith('0')) {
    final stripped = compact.replaceFirst(RegExp(r'^0+'), '');
    if (stripped.length >= 5 && !numberCandidates.contains(stripped)) {
      numberCandidates.add(stripped);
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

  if (RegExp(r'^\d{5,}$').hasMatch(text)) {
    addNumber(text);
  }

  if (RegExp(r'^\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+$')
      .hasMatch(text)) {
    addNumber(text);
  }
}

  // 2. Danach Zahlen aus dem gesamten OCR-Text ziehen
  final combinedText = [
    rawText,
    ...boxes.map((e) => e.text),
  ].join(' ');

  for (final match in RegExp(r'\b\d{5,}\b').allMatches(combinedText)) {
    final value = match.group(0);
    if (value != null) {
      addNumber(value);
    }
  }

  for (final match in RegExp(r'\d{2,5}[.\-\/]\d{2,6}([.\-\/]\d{2,6})+')
    .allMatches(combinedText)) {
  final value = match.group(0);
  if (value != null) {
    addNumber(value);
  }
}

  debugPrint('FAST OCR NUMBER CANDIDATES: $numberCandidates');

  final results = <OcrCatalogMatch>[];
  final seen = <String>{};

  for (final number in numberCandidates.take(12)) {
    final found = _fastLocalOcrSearch(number, limit: 3);

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

      if (results.length >= 3) {
        debugPrint(
          'FAST OCR NUMBER MATCHES: ${results.map((e) => '${e.item.basename} | ${e.usedTerm}').toList()}',
        );
        return results;
      }
    }
  }

  return results;
}

List<OcrCatalogMatch> _findBestSmartOcrCatalogMatches(
  String rawText,
  List<OcrBoxCandidate> boxes,
) {
  final candidates = _buildSmartOcrCandidates(rawText, boxes);

  final scoredMatches = <OcrCatalogMatch>[];
  final seenItems = <String>{};

  // Wichtig für Geschwindigkeit:
  // Nicht mehr 80 Kandidaten prüfen, sondern nur die besten 15.
  for (final candidate in candidates.take(11)) {
    final prefilteredItems = _fastLocalOcrSearch(candidate, limit: 8);

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

    if (uniqueMatches.length >= 3) {
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

Future<void> _runLocalOcr(ImageSource source) async {
  try {
    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(
      source: source,
      imageQuality: 90,
    );

    if (picked == null) return;
    if (!mounted) return;

    setState(() {
      _searchLoading = true;
      _message = '';
      _ocrBoxTexts = [];
      _results = [];
      _showOcrSuggestions = false;
      _activeHighlightTerm = '';
    });

    final inputImage = InputImage.fromFilePath(picked.path);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

    final RecognizedText recognizedText =
        await textRecognizer.processImage(inputImage);

    await textRecognizer.close();

    if (!mounted) return;

    final sortedBoxes = _extractOcrBoxCandidatesSorted(recognizedText);
    final rawText = recognizedText.text.trim();
    final preferredArticle = _extractPreferredArticleNumber(rawText);
    final visibleBoxTexts = sortedBoxes.map((e) => e.text).take(12).toList();

    debugPrint('OCR RAW TEXT: $rawText');
    debugPrint('OCR PREFERRED ARTICLE: $preferredArticle');
    debugPrint(
      'OCR BOXES SORTED: ${sortedBoxes.map((e) => '${e.text} (${e.area.toStringAsFixed(0)})').toList()}',
    );

List<CatalogItem> matches = [];
String usedSearchText = '';
int smartOcrScore = 0;

final fastNumberMatches = _findFastNumberOcrMatches(rawText, sortedBoxes);

if (fastNumberMatches.isNotEmpty) {
  matches = fastNumberMatches.map((e) => e.item).toList();
  usedSearchText = fastNumberMatches.first.usedTerm;
  smartOcrScore = fastNumberMatches.first.score;
} else {
  final smartMatches = _findBestSmartOcrCatalogMatches(rawText, sortedBoxes);

  if (smartMatches.isNotEmpty) {
    matches = smartMatches.map((e) => e.item).toList();
    usedSearchText = smartMatches.first.usedTerm;
    smartOcrScore = smartMatches.first.score;
  }
}

    // Sehr eindeutiger Fallback, falls deine Preferred-Article-Erkennung
    // irgendwann eine konkrete Nummer erkennt.
    if (matches.isEmpty &&
        preferredArticle != null &&
        preferredArticle.isNotEmpty) {
      final found = _localOcrSearch(preferredArticle);

      if (found.isNotEmpty) {
        matches = found.take(3).toList();
        usedSearchText = preferredArticle;
        smartOcrScore = 9999;
      }
    }

    if (!mounted) return;

    if (matches.isEmpty) {
      setState(() {
        _searchLoading = false;
        _results = [];
        _ocrBoxTexts = visibleBoxTexts;
        _showOcrSuggestions = true;
        _message = 'Keine hinterlegten Artikel im Aufkleber gefunden.';
      });
      return;
    }

    setState(() {
      _searchLoading = false;
      _results = matches;
      _ocrBoxTexts = visibleBoxTexts;
      _showOcrSuggestions = false;
      _activeHighlightTerm = usedSearchText;

      if (usedSearchText.isNotEmpty) {
        _message =
            'ATool-Treffer über intelligente Suche: $usedSearchText – beste ${matches.length} Treffer angezeigt.';
      } else {
        _message = '';
      }
    });

    if (usedSearchText.isNotEmpty) {
      _setSearchTextSilently(usedSearchText);
    }

    debugPrint('SMART OCR FINAL SCORE: $smartOcrScore');

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${matches.length} Artikel aus dem Aufkleber gefunden.'),
      ),
    );
  } catch (e, stackTrace) {
    debugPrint('OCR ERROR: $e');
    debugPrint('$stackTrace');

    if (!mounted) return;

    setState(() {
      _searchLoading = false;
      _message = 'Kamera/OCR fehlgeschlagen.';
    });
  }
}

  Future<void> _loadDwgDisplayCount() async {
  try {
    final resp = await http.get(Uri.parse(AppConfig.dwgListUrl));
    final data = jsonDecode(resp.body);

    if (data is Map<String, dynamic>) {
      final count = data.keys.length;

      if (!mounted) return;

      setState(() {
        _dwgDisplayCount = count;
      });
    }
  } catch (_) {
    // absichtlich still
  }
}

  Future<void> _handleSearchDirect(String term) async {
  final q = term.trim();
  if (q.length < minSearchLen) return;

  setState(() {
    _searchLoading = true;
    _message = '';
    _showOcrSuggestions = false;
    _ocrBoxTexts = [];
    _activeHighlightTerm = q;
  });

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

    setState(() {
      _results = found;
      _searchLoading = false;
      _activeHighlightTerm = usedSearchTerm;

      if (found.isNotEmpty && usedSearchTerm != q) {
        _message =
            'Kein exakter Treffer für "$q". Treffer für "$usedSearchTerm" angezeigt.';
      } else {
        _message = '';
      }
    });

    unawaited(
      http.post(
        Uri.parse(AppConfig.logUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'term': q,
          'used_term': usedSearchTerm,
          'found': found.isNotEmpty ? 1 : 0,
        }),
      ),
    );
  } catch (_) {
    if (!mounted) return;
    setState(() {
      _searchLoading = false;
      _message = 'Suche fehlgeschlagen.';
    });
  }
}

  void _showInfoDialog() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const InfoLicensePage()),
    );
  }

Future<void> _applyOcrSuggestion(String term) async {
  final q = term.trim();
  if (q.isEmpty) return;

  _searchController.text = q;
  _searchController.selection = TextSelection.fromPosition(
    TextPosition(offset: q.length),
  );

  await _handleSearchDirect(q);
}

  Future<void> _openImageViewer(String imageUrl, String filename) async {
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewerPage(
          imageUrl: imageUrl,
          filename: filename,
        ),
      ),
    );
  }

Future<String?> _pickDownloadDirectory() async {
  try {
    final String? dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Download-Ordner wählen',
    );
    return dir;
  } catch (_) {
    return null;
  }
}

Future<bool> _askUseSavedDirectory(String dirPath) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Download-Ziel'),
      content: Text('Gespeicherten Ordner verwenden?\n\n$dirPath'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Neuen Ordner wählen'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Verwenden'),
        ),
      ],
    ),
  );

  return result ?? false;
}

Future<void> _saveBytesToDirectory({
  required Uint8List bytes,
  required String directoryPath,
  required String fileName,
}) async {
  final file = File('$directoryPath${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes, flush: true);
}

Future<void> _downloadWithTarget(String fileUrl, String filename) async {
  try {
    final response = await http.get(Uri.parse(fileUrl));

    if (!mounted) return;

    if (response.statusCode != 200) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Download fehlgeschlagen (${response.statusCode})'),
        ),
      );
      return;
    }

    final Uint8List bytes = response.bodyBytes;
    final String saveName = _safeDxfFileName(filename);

    String? directoryPath = await DownloadPrefs.getDownloadDir();

    if (!mounted) return;

    if (directoryPath != null && directoryPath.isNotEmpty) {
      final reuse = await _askUseSavedDirectory(directoryPath);

      if (!mounted) return;

      if (!reuse) {
        directoryPath = await _pickDownloadDirectory();
      }
    } else {
      directoryPath = await _pickDownloadDirectory();
    }

    if (!mounted) return;

    if (directoryPath == null || directoryPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ordnerauswahl abgebrochen.')),
      );
      return;
    }

    await _saveBytesToDirectory(
      bytes: bytes,
      directoryPath: directoryPath,
      fileName: saveName,
    );

    await DownloadPrefs.setDownloadDir(directoryPath);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Gespeichert in: $directoryPath'),
      ),
    );
  } catch (_) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Download oder Speichern fehlgeschlagen.'),
      ),
    );
  }
}

Future<void> _openExternalLink(String url) async {
  final uri = Uri.parse(url);

  final ok = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
  );

  if (!mounted) return;

  if (!ok) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Link konnte nicht geöffnet werden: $url'),
      ),
    );
  }
}

Future<void> _searchPdfOnWeb({
  required String filename,
  String? manufacturer,
}) async {
  final raw = filename.trim();
  final maker = (manufacturer ?? '').trim();

  if (raw.isEmpty) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Kein Dateiname für die PDF-Suche verfügbar.'),
      ),
    );
    return;
  }

  final parts = raw
      .split(RegExp(r'\s+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  final mainQuery = [
    '"$raw"',
    ...parts.map((p) => '"$p"'),
  ].join(' OR ');

  final query = maker.isNotEmpty
      ? '($mainQuery) "$maker" filetype:pdf'
      : '$mainQuery filetype:pdf';

  final uri = Uri.parse(
    'https://www.google.com/search?q=${Uri.encodeQueryComponent(query)}',
  );

  final ok = await launchUrl(
    uri,
    mode: LaunchMode.inAppBrowserView,
  );

  if (!mounted) return;

  if (!ok) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('PDF-Suche konnte nicht geöffnet werden.'),
      ),
    );
  }
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
            style: highlightStyle ??
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

  @override
Widget build(BuildContext context) {
  final rawSearch = _searchController.text.trim();
final search = _activeHighlightTerm.isNotEmpty
    ? _activeHighlightTerm
    : rawSearch;
  final compactHeight = MediaQuery.sizeOf(context).height < 430;

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
            Container(
            color: const Color(0xFF2C2C2C),
            padding: compactHeight
            ? const EdgeInsets.fromLTRB(12, 6, 12, 8)
            : const EdgeInsets.fromLTRB(16, 12, 16, 18),
            child: Column(
              children: [
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
                        textInputAction: TextInputAction.search,
                        onSubmitted: _handleSearchDirect,
                        decoration: InputDecoration(
                          hintText:
                              'Artikelnummer eingeben (min. $minSearchLen Zeichen)…',
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
                      icon: Icons.info_outline,
                      onTap: _showInfoDialog,
                      smallIcon: true,
                    ),
                  ],
                ),
                SizedBox(height: compactHeight ? 6 : 14),
                if (!compactHeight)
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
                              const TextSpan(text: 'Verfügbare Ausschnitte: '),
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
                          const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text('Suche läuft…'),
                          ),
if (_message.isNotEmpty)
  Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      _message,
      style: TextStyle(
        color: _results.isNotEmpty
            ? const Color(0xFFB26A00)
            : Colors.red,
        fontWeight: FontWeight.w600,
      ),
    ),
  ),
if (_ocrBoxTexts.isNotEmpty && _results.isEmpty)
  Container(
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
                const Expanded(
                  child: Text(
                    'Keine Treffer? OCR-Begriffe anzeigen',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
                Icon(
                  _showOcrSuggestions
                      ? Icons.expand_less
                      : Icons.expand_more,
                ),
              ],
            ),
          ),
        ),
        if (_showOcrSuggestions) ...[
          const Divider(height: 1),
          Padding(
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
        ],
      ],
    ),
  ),
                        if (!_searchLoading &&
                            _results.isEmpty &&
                            rawSearch.length >= minSearchLen)
                          const Padding(
                            padding: EdgeInsets.only(top: 20),
                            child: Text(
                              'Artikel noch nicht hinterlegt.',
                              style: TextStyle(
                                fontSize: 16,
                                color: Color(0xFF666666),
                              ),
                            ),
                          ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _results.length,
                            itemBuilder: (context, index) {
                              final item = _results[index];
                              final filename = item.basename;
                              final einbauTyp = item.type;
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                    const SizedBox(height: 12),
LayoutBuilder(
  builder: (context, constraints) {
    final useVerticalButtons = constraints.maxWidth < 520;

    final viewButton = ElevatedButton.icon(
      onPressed: item.jpgExists && imageUrlSafe.isNotEmpty
          ? () {
              _openImageViewer(imageUrlSafe, filename);
            }
          : null,
      icon: const Icon(Icons.remove_red_eye_outlined),
      label: const Text('Ansehen'),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF2C2C2C),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );

    final downloadButton = ElevatedButton.icon(
      onPressed: item.dxfExists && downloadUrlSafe.isNotEmpty
          ? () {
              _downloadWithTarget(downloadUrlSafe, filename);
            }
          : null,
      icon: const Icon(Icons.download_outlined),
      label: const Text('Download'),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF444444),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );

    final pdfButton = ElevatedButton.icon(
      onPressed: () {
        _searchPdfOnWeb(
          filename: filename,
          manufacturer: item.manufacturer,
        );
      },
      icon: const Icon(Icons.picture_as_pdf_outlined),
      label: const Text('PDF suchen'),
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF666666),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );

    if (useVerticalButtons) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          Container(
  color: const Color(0xFF2C2C2C),
  padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
  child: Row(
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
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    ],
  ),
),
        ],
      ),
      )
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

  @override
  void initState() {
    super.initState();
    _init();
  }

Future<void> _init() async {
  try {
    final uuid = await AppStorage.getOrCreateDeviceUuid();
    final meta = await DeviceMetaService.load();
    final data = await ApiService.getLicenseStatus();
    final lastDir = await DownloadPrefs.getDownloadDir();

    if (!mounted) return;

    setState(() {
      _deviceUuid = uuid;
      _deviceMeta = meta;
      _downloadDir = lastDir ?? '';

      if (data['success'] == true) {
        _data = data;
      } else {
        _message =
            (data['message'] ?? 'Lizenzstatus konnte nicht geladen werden.')
                .toString();
      }

      _loading = false;
    });
  } catch (_) {
    if (!mounted) return;
    setState(() {
      _message = 'Info-Bereich konnte nicht geladen werden.';
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
      title: const Text('Hinweise zur Nutzung'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ATool unterstützt bei der Suche nach Artikeln, Zeichnungen und Produktinformationen.',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),

              _infoSection(
                icon: Icons.info_outline,
                title: 'Was macht ATool?',
                text:
                    'Die App dient als internes Hilfsmittel zur schnellen Orientierung im Arbeitsalltag und unterstützt bei der Identifikation von Artikeln und zugehörigen Dateien.',
              ),
              const SizedBox(height: 14),

              _infoSection(
                icon: Icons.verified_outlined,
                title: 'Hinweis zur Datenqualität',
                text:
                    'Die angezeigten Inhalte werden sorgfältig bereitgestellt. Dennoch können Informationen im Einzelfall unvollständig, veraltet oder fehlerhaft sein. Verbindlich bleiben die jeweils freigegebenen technischen Unterlagen und internen Datenquellen.',
              ),
              const SizedBox(height: 14),

              _infoSection(
                icon: Icons.document_scanner_outlined,
                title: 'Hinweis zur OCR-Erkennung',
                text:
                    'Die automatische Texterkennung erleichtert das Erfassen von Aufklebern und Beschriftungen. Je nach Bildqualität, Perspektive oder Verschmutzung können jedoch fehlerhafte oder unvollständige Ergebnisse entstehen. Erkannte Suchbegriffe und Treffer sollten deshalb vor der weiteren Verwendung geprüft werden.',
              ),
              const SizedBox(height: 14),

              _infoSection(
                icon: Icons.business_center_outlined,
                title: 'Nutzung',
                text:
                    'Die Anwendung ist ausschließlich für den vorgesehenen betrieblichen Einsatz bestimmt.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Schließen'),
        ),
      ],
    ),
  );
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
      border: Border.all(
        color: Colors.grey.withValues(alpha: 0.18),
      ),
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

  @override
  Widget build(BuildContext context) {
    final firm = _data?['firm'] as Map<String, dynamic>?;
    final user = _data?['user'] as Map<String, dynamic>?;
    final device = _data?['device'] as Map<String, dynamic>?;

    final firmStatus = (firm?['status'] ?? '').toString();
    final deviceStatus = (device?['status'] ?? '').toString();

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Info & Lizenz'),
        actions: [
          IconButton(
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
                              color: Colors.red.withValues (alpha: 0.08),
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
                        const Text(
                          'Lizenzübersicht',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _InfoCard(
                          title: 'Benutzer',
                          icon: Icons.person_outline,
                          children: [
                            _InfoRow(
                              label: 'Name',
                              value: '${user?['name'] ?? ''}',
                            ),
                            _InfoRow(
                              label: 'E-Mail',
                              value: '${user?['email'] ?? ''}',
                            ),
                            _InfoRow(
                              label: 'Rolle',
                              value: '${user?['role'] ?? ''}',
                            ),
                          ],
                        ),
                        _InfoCard(
                          title: 'Firma',
                          icon: Icons.business_outlined,
                          children: [
                            _InfoRow(
                              label: 'Name',
                              value: '${firm?['name'] ?? ''}',
                            ),
                            _StatusRow(label: 'Status', value: firmStatus),
                            _InfoRow(
                              label: 'Max Geräte',
                              value: '${firm?['max_devices'] ?? ''}',
                            ),
                            _InfoRow(
                              label: 'Lizenz bis',
                              value: '${firm?['license_end'] ?? ''}',
                            ),
                            _InfoRow(
                              label: 'Tage übrig',
                              value: '${firm?['days_left'] ?? ''}',
                            ),
                          ],
                        ),
                        _InfoCard(
                          title: 'Gerät',
                          icon: Icons.tablet_android_outlined,
                          children: [
                            _InfoRow(
                              label: 'Lokale Geräte-ID',
                              value: _deviceUuid,
                            ),
                            _InfoRow(
                              label: 'Erkanntes Gerät',
                              value: _deviceMeta?.deviceName ?? '',
                            ),
                            _InfoRow(
                              label: 'Erkanntes OS',
                              value: _deviceMeta?.osVersion ?? '',
                            ),
                            _InfoRow(
                              label: 'App-Version',
                              value: _deviceMeta?.appVersion ?? '',
                            ),
                            _InfoRow(
                              label: 'Server UUID',
                              value: '${device?['device_uuid'] ?? ''}',
                            ),
                            _InfoRow(
                              label: 'Server-Name',
                              value: '${device?['device_name'] ?? ''}',
                            ),
                            _StatusRow(
                              label: 'Gerätestatus',
                              value: deviceStatus,
                            ),
                          ],
                        ),

_InfoCard(
  title: 'Download-Ziel',
  icon: Icons.folder_outlined,
  children: [
    _InfoRow(
      label: 'Ordner',
      value: _downloadDir.isEmpty ? 'Noch nicht gewählt' : _downloadDir,
    ),
  ],
),
SizedBox(
  width: double.infinity,
  child: OutlinedButton.icon(
onPressed: () async {
  await DownloadPrefs.clearDownloadDir();
  if (!mounted) return;

  setState(() {
    _downloadDir = '';
  });

  ScaffoldMessenger.of(this.context).showSnackBar(
    const SnackBar(
      content: Text('Gemerktes Download-Ziel zurückgesetzt.'),
    ),
  );
},
    icon: const Icon(Icons.delete_outline),
    label: const Text('Download-Ziel zurücksetzen'),
  ),
),

                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _showLicenseAgreement,
                            icon: const Icon(Icons.description_outlined),
                            label: const Text('Lizenzvereinbarung anzeigen'),
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: Color(0xFFE5E5E5))),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Schließen'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _logout,
                          child: const Text('Logout'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class ImageViewerPage extends StatelessWidget {
  final String imageUrl;
  final String filename;

  const ImageViewerPage({
    super.key,
    required this.imageUrl,
    required this.filename,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(filename),
      ),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: Image.network(
            imageUrl,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Vorschaubild konnte nicht geladen werden.',
                style: TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ),
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const Center(
                child: CircularProgressIndicator(),
              );
            },
          ),
        ),
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
          child: Icon(
            icon,
            size: smallIcon ? 20 : 28,
            color: Colors.black,
          ),
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
      elevation: 3,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
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

  const _InfoRow({
    required this.label,
    required this.value,
  });

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
          Expanded(
            child: SelectableText(value),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatusRow({
    required this.label,
    required this.value,
  });

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
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}