import 'dart:async';
import 'dart:convert';

import 'package:atool_app/android_session_restore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('de.adleraufmasse.atool/restore_credentials');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AndroidSessionRestore service;

  setUp(() {
    final previousPreferences = SharedPreferencesAsyncPlatform.instance;
    final previousPlatform = debugDefaultTargetPlatformOverride;
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    service = AndroidSessionRestore(
      endpoint: Uri.https('example.test', '/restore-credentials.php'),
      readAccessToken: () async => 'old-access',
      refreshAccessToken: () async => fail('Unexpected token refresh'),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      SharedPreferencesAsyncPlatform.instance = previousPreferences;
      debugDefaultTargetPlatformOverride = previousPlatform;
    });
  });

  test('registers the native key once for an active session', () async {
    final requests = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isSupported') return true;
      expect(call.method, 'create');
      expect(jsonDecode(call.arguments as String), {'challenge': 'register'});
      return '{"rawId":"new-key"}';
    });
    await http.runWithClient(
      () async {
        await service.enroll();
        await service.enroll();
      },
      () => MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body['action'] as String);
        expect(request.headers['authorization'], 'Bearer old-access');
        if (body['action'] == 'register-options') {
          return http.Response('{"options":{"challenge":"register"}}', 200);
        }
        expect(body['credential'], {'rawId': 'new-key'});
        return http.Response('{"success":true}', 200);
      }),
    );
    expect(requests, ['register-options', 'register']);
  });

  test('exchanges the transferred key for fresh session tokens', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isSupported') return true;
      expect(call.method, 'get');
      expect(jsonDecode(call.arguments as String), {'challenge': 'restore'});
      return '{"rawId":"transferred-key"}';
    });
    final session = await http.runWithClient(
      () => service.tryRestore('new-device', () async => {'app_version': '1'}),
      () => MockClient((request) async {
        expect(request.headers['authorization'], isNull);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['device_uuid'], 'new-device');
        if (body['action'] == 'restore-options') {
          return http.Response('{"options":{"challenge":"restore"}}', 200);
        }
        expect(body['action'], 'restore');
        expect(body['credential'], {'rawId': 'transferred-key'});
        expect(body['app_version'], '1');
        return http.Response(
          '{"success":true,"session":{"access_token":"new","refresh_token":"refresh"}}',
          200,
        );
      }),
    );
    expect(session, (accessToken: 'new', refreshToken: 'refresh'));
  });

  test('a signed-out installation skips restore after a restart', () async {
    var cleared = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isSupported') return true;
      expect(call.method, 'clear');
      cleared = true;
      return true;
    });
    await service.discard();
    expect(cleared, isTrue);
    final restarted = AndroidSessionRestore(
      endpoint: service.endpoint,
      readAccessToken: service.readAccessToken,
      refreshAccessToken: service.refreshAccessToken,
    );
    final session = await http.runWithClient(
      () => restarted.tryRestore('old-device', () async => {}),
      () => MockClient((_) async => fail('Unexpected restore after logout')),
    );
    expect(session, isNull);
  });

  test('signing out while a key is being created clears it', () async {
    final creating = Completer<void>();
    final registration = Completer<String>();
    var cleared = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isSupported') return true;
      if (call.method == 'create') {
        creating.complete();
        return registration.future;
      }
      expect(call.method, 'clear');
      cleared = true;
      return true;
    });
    await http.runWithClient(
      () async {
        final enroll = service.enroll();
        await creating.future;
        final logout = service.discard();
        registration.complete('{"rawId":"new-key"}');
        await Future.wait([enroll, logout]);
      },
      () => MockClient((request) async {
        expect(jsonDecode(request.body)['action'], 'register-options');
        return http.Response('{"options":{"challenge":"register"}}', 200);
      }),
    );
    expect(cleared, isTrue);
  });
}
