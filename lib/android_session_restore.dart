import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

typedef RestoredSession = ({String accessToken, String refreshToken});

class AndroidSessionRestore {
  AndroidSessionRestore({
    required this.endpoint,
    required this.readAccessToken,
    required this.refreshAccessToken,
  });

  final Uri endpoint;
  final Future<String?> Function() readAccessToken;
  final Future<void> Function() refreshAccessToken;

  static const _channel = MethodChannel(
    'de.adleraufmasse.atool/restore_credentials',
  );
  static const _enrolledAtKey = 'android_restore_enrolled_at';
  static const _skipRestoreKey = 'android_restore_skip';
  static const _requestTimeout = Duration(seconds: 4);
  static const _renewalInterval = Duration(days: 180);

  Future<void>? _enrollment;
  bool _signedOut = false;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool> _isSupported() async =>
      _isAndroid && await _channel.invokeMethod<bool>('isSupported') == true;

  Future<void> enroll({bool newSession = false}) {
    if (!_isAndroid) return Future.value();
    if (newSession) _signedOut = false;
    if (_signedOut) return Future.value();
    return _enrollment ??= _enroll(newSession: newSession).whenComplete(() {
      _enrollment = null;
    });
  }

  Future<void> _enroll({required bool newSession}) async {
    try {
      final prefs = SharedPreferencesAsync();
      if (newSession) await prefs.remove(_enrolledAtKey);
      final enrolledAt = await prefs.getInt(_enrolledAtKey);
      if (enrolledAt != null) {
        final age = DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(enrolledAt),
        );
        if (!age.isNegative && age < _renewalInterval) return;
      }
      if (!await _isSupported() || _signedOut) return;

      var token = await readAccessToken();
      if (token == null || token.isEmpty) return;
      var response = await _post('register-options', token: token);
      if (response.statusCode == 401 && !_signedOut) {
        await refreshAccessToken();
        token = await readAccessToken();
        if (token == null || token.isEmpty) return;
        response = await _post('register-options', token: token);
      }
      if (response.statusCode != 200 || _signedOut) return;
      final options = _decode(response)['options'];
      if (options is! Map) return;

      final registration = await _channel.invokeMethod<String>(
        'create',
        jsonEncode(options),
      );
      if (registration == null || _signedOut) return;
      final registered = await _post(
        'register',
        token: token,
        data: {'credential': jsonDecode(registration)},
      );
      if (registered.statusCode == 200 &&
          _decode(registered)['success'] == true &&
          !_signedOut) {
        await prefs.setInt(
          _enrolledAtKey,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
    } catch (_) {
      // Enrollment is retried at a subsequent signed-in launch.
    }
  }

  Future<RestoredSession?> tryRestore(
    String deviceUuid,
    Future<Map<String, String>> Function() readDeviceDetails,
  ) async {
    try {
      if (_signedOut || !await _isSupported()) return null;
      final prefs = SharedPreferencesAsync();
      if (await prefs.getBool(_skipRestoreKey) == true ||
          await prefs.getInt(_enrolledAtKey) != null) {
        return null;
      }
      final device = {'device_uuid': deviceUuid};
      final response = await _post('restore-options', data: device);
      if (response.statusCode != 200) return null;
      final options = _decode(response)['options'];
      if (options is! Map) return null;

      final assertion = await _channel.invokeMethod<String>(
        'get',
        jsonEncode(options),
      );
      if (assertion == null) {
        await prefs.setBool(_skipRestoreKey, true);
        return null;
      }
      final restored = await _post(
        'restore',
        data: {
          ...await readDeviceDetails(),
          ...device,
          'credential': jsonDecode(assertion),
        },
      );
      if (restored.statusCode == 401 || restored.statusCode == 403) {
        await discard();
        return null;
      }
      if (restored.statusCode != 200) return null;
      final data = _decode(restored);
      final session = data['session'];
      if (data['success'] != true || session is! Map) return null;
      final access = session['access_token'];
      final refresh = session['refresh_token'];
      if (access is! String ||
          access.isEmpty ||
          refresh is! String ||
          refresh.isEmpty) {
        return null;
      }
      return (accessToken: access, refreshToken: refresh);
    } catch (_) {
      return null;
    }
  }

  Future<void> discard() async {
    if (!_isAndroid) return;
    _signedOut = true;
    await _enrollment;
    try {
      final prefs = SharedPreferencesAsync();
      await prefs.setBool(_skipRestoreKey, true);
      await prefs.remove(_enrolledAtKey);
    } catch (_) {
      // Still try to delete the credential from Credential Manager.
    }
    try {
      if (await _isSupported()) await _channel.invokeMethod<bool>('clear');
    } catch (_) {
      // The local marker still prevents signing back in on this installation.
    }
  }

  Future<http.Response> _post(
    String action, {
    String? token,
    Map<String, Object?> data = const {},
  }) => http
      .post(
        endpoint,
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode({...data, 'action': action}),
      )
      .timeout(_requestTimeout);

  Map<String, dynamic> _decode(http.Response response) =>
      jsonDecode(response.body) as Map<String, dynamic>;
}
