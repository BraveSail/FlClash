import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('getTextResponseForUrl propagates the typed DioException', () async {
    // flutter_test's mocked HttpClient answers every request with HTTP 400,
    // which Dio surfaces as a badResponse DioException.
    await expectLater(
      request.getTextResponseForUrl('http://127.0.0.1/anything'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
  });

  test('getFileResponseForUrl propagates the typed DioException', () async {
    await expectLater(
      request.getFileResponseForUrl('http://127.0.0.1/anything'),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.badResponse,
        ),
      ),
    );
  });

  group('getFileResponseForUrl against a real origin', () {
    late HttpServer server;
    late String origin;
    late String? authorization;

    setUp(() async {
      // The suite's mocked HttpClient would answer 400 to everything.
      HttpOverrides.global = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin = 'http://${server.address.host}:${server.port}';
      unawaited(
        server.forEach((req) async {
          authorization = req.headers.value(HttpHeaders.authorizationHeader);
          req.response
            ..statusCode = HttpStatus.ok
            ..write('mesh:\n  proxy: {type: vless}\n');
          await req.response.close();
        }),
      );
    });

    tearDown(() async {
      await server.close(force: true);
    });

    tearDownAll(() {
      // The shared request keeps a reader; leave a live container behind
      // rather than a disposed one.
      final container = ProviderContainer();
      request.attach(container.read);
    });

    test('sends the headers it was given on a direct connection', () async {
      final response = await request.getFileResponseForUrl(
        '$origin/profile?id=abc',
        headers: const {'Authorization': 'Bearer explicit'},
        viaProxy: false,
      );

      expect(authorization, 'Bearer explicit');
      expect(String.fromCharCodes(response.data!), contains('mesh:'));
    });

    test('works without headers', () async {
      await request.getFileResponseForUrl('$origin/profile', viaProxy: false);

      expect(authorization, isNull);
    });

    test('the hub settings authenticate their own profile request', () async {
      final container = ProviderContainer(
        overrides: [
          appSettingProvider.overrideWithBuild(
            (_, _) => AppSettingProps(
              hubUrl: origin,
              hubToken: 'secret',
              hubViaProxy: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      request.attach(container.read);

      await request.getFileResponseForUrl('$origin/profile?id=abc');

      expect(authorization, 'Bearer secret');
    });

    test('another origin never sees the hub token', () async {
      final container = ProviderContainer(
        overrides: [
          appSettingProvider.overrideWithBuild(
            (_, _) => AppSettingProps(
              hubUrl: 'https://hub.example',
              hubToken: 'secret',
              hubViaProxy: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      request.attach(container.read);

      await request.getFileResponseForUrl('$origin/profile', viaProxy: false);

      expect(authorization, isNull);
    });
  });
}
