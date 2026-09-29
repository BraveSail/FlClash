import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/state.dart';

class Request {
  late final Dio dio;
  late final Dio _clashDio;
  late final Dio _directDio;
  String? userAgent;

  ProviderReader? _read;

  void attach(ProviderReader read) {
    _read = read;
  }

  Request() {
    dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _clashDio = Dio();
    _clashDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          final read = _read;
          if (read == null) {
            return 'DIRECT';
          }
          return FlClashHttpOverrides.findProxyForReader(read, uri);
        };
        return client;
      },
    );
    _directDio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _directDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        // Plain `dio` is not enough to stay off the proxy: its default adapter
        // builds its client through HttpOverrides.global, which the app points
        // at the running core, so the override has to be undone here.
        client.findProxy = (uri) => 'DIRECT';
        return client;
      },
    );
  }

  ({Map<String, String> headers, bool viaProxy})? _hubConnectionFor(
    String url,
  ) {
    final read = _read;
    if (read == null) {
      return null;
    }
    final setting = read(appSettingProvider);
    if (!isHubEnabled(setting.hubUrl, setting.hubToken) ||
        !isHubUrl(url, setting.hubUrl)) {
      return null;
    }
    return (
      headers: hubAuthHeaders(setting.hubToken),
      viaProxy: setting.hubViaProxy,
    );
  }

  /// Run a request, falling back to the other path when the preferred one
  /// fails.
  ///
  /// The hub is reachable both through the core and straight out, and which of
  /// the two works is not a property of the URL: the proxy can be down, the
  /// core may not be up yet, or the rule set may send the hub somewhere it
  /// cannot go, while the direct path is fine - and the reverse holds when the
  /// network blocks the hub and only the tunnel reaches it. Trying one and then
  /// the other turns either outage into a slowdown instead of a failure to load
  /// the profile, so the caller does not have to know which is up.
  ///
  /// Only a preference falls back, never an instruction: a caller that hands
  /// `viaProxy` as an argument is saying which path it wants and gets that path
  /// or its error, while the hub setting is a default the app is free to work
  /// around when it cannot be honoured.
  Future<Response<T>> _withFallback<T>(
    Future<Response<T>> Function(Dio client) send, {
    required bool preferredViaProxy,
    String? what,
  }) async {
    final proxy = _clashDio;
    final direct = _directDio;
    final order = preferredViaProxy ? [proxy, direct] : [direct, proxy];
    Object? firstError;
    for (var i = 0; i < order.length; i++) {
      try {
        return await send(order[i]);
      } catch (e) {
        final path = identical(order[i], proxy) ? 'proxy' : 'direct';
        if (i == 0) {
          firstError = e;
          commonPrint.log(
            '${what ?? 'request'}: $path failed '
            '(${compactError(e)}), trying the other path',
            logLevel: LogLevel.debug,
          );
          continue;
        }
        commonPrint.log(
          '${what ?? 'request'}: $path also failed '
          '(${compactError(e)}); first error was ${compactError(firstError ?? e)}',
          logLevel: LogLevel.warning,
        );
        rethrow;
      }
    }
    throw StateError('unreachable');
  }

  Future<Response<Uint8List>> getFileResponseForUrl(
    String url, {
    Map<String, String>? headers,
    bool? viaProxy,
  }) async {
    final hub = _hubConnectionFor(url);
    // An explicit argument is followed exactly; only the hub's own preference
    // is allowed to fall back, because that one is a default rather than an
    // instruction. Falling back past an explicit choice would send a request
    // somewhere the caller said not to.
    final requested = viaProxy;
    final headersFor = headers ?? hub?.headers;
    try {
      if (requested != null) {
        return await (requested ? _clashDio : _directDio).get<Uint8List>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            headers: headersFor,
          ),
        );
      }
      return await _withFallback<Uint8List>(
        (client) => client.get<Uint8List>(
          url,
          options: Options(
            responseType: ResponseType.bytes,
            headers: headersFor,
          ),
        ),
        preferredViaProxy: hub?.viaProxy ?? true,
        what: 'getFileResponseForUrl $url',
      );
    } catch (e) {
      commonPrint.log(
        'getFileResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  Future<Response<String>> getTextResponseForUrl(
    String url, {
    Map<String, String>? headers,
  }) async {
    final hub = _hubConnectionFor(url);
    final preferredViaProxy = hub?.viaProxy ?? true;
    try {
      return await _withFallback<String>(
        (client) => client.get<String>(
          url,
          options: Options(
            responseType: ResponseType.plain,
            headers: headers ?? hub?.headers,
          ),
        ),
        preferredViaProxy: preferredViaProxy,
        what: 'getTextResponseForUrl $url',
      );
    } catch (e) {
      commonPrint.log(
        'getTextResponseForUrl error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      rethrow;
    }
  }

  /// Reads the device list from the hub. Null means the list could not be
  /// read: the caller then leaves the mesh block unresolved rather than
  /// freezing an empty one, so the core keeps reading it itself when it can.
  Future<List<HubDevice>?> getHubDevices(String hubUrl, String hubToken) async {
    final url = hubDevicesUrl(hubUrl);
    if (url.isEmpty) {
      return null;
    }
    final setting = _read?.call(appSettingProvider);
    final preferredViaProxy = setting?.hubViaProxy ?? true;
    try {
      final response = await _withFallback<Map<String, dynamic>>(
        (client) => client.get<Map<String, dynamic>>(
          url,
          options: Options(
            responseType: ResponseType.json,
            headers: hubAuthHeaders(hubToken),
          ),
        ),
        preferredViaProxy: preferredViaProxy,
        what: 'getHubDevices',
      );
      return parseHubDevices(response.data);
    } catch (e) {
      commonPrint.log(
        'getHubDevices error ${compactError(e)}',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final response = await dio.get(
        'https://api.github.com/repos/$repository/releases/latest',
        options: Options(responseType: ResponseType.json),
      );
      if (response.statusCode != 200) return null;
      final data = response.data as Map<String, dynamic>;
      final remoteVersion = data['tag_name'];
      final version = globalState.packageInfo.version;
      final hasUpdate =
          compareVersions(remoteVersion.replaceAll('v', ''), version) > 0;
      if (!hasUpdate) return null;
      return data;
    } catch (e) {
      commonPrint.log('checkForUpdate failed', logLevel: LogLevel.warning);
      return null;
    }
  }

  final Map<String, IpInfo Function(Map<String, dynamic>)> _ipInfoSources = {
    'https://ipwho.is': IpInfo.fromIpWhoIsJson,
    'https://api.myip.com': IpInfo.fromMyIpJson,
    'https://ipapi.co/json': IpInfo.fromIpApiCoJson,
    'https://ident.me/json': IpInfo.fromIdentMeJson,
    'http://ip-api.com/json': IpInfo.fromIpAPIJson,
    'https://api.ip.sb/geoip': IpInfo.fromIpSbJson,
    'https://ipinfo.io/json': IpInfo.fromIpInfoIoJson,
  };

  Future<Result<IpInfo?>> checkIp({CancelToken? cancelToken}) async {
    var failureCount = 0;
    final token = cancelToken ?? CancelToken();
    final futures = _ipInfoSources.entries.map((source) async {
      final Completer<Result<IpInfo?>> completer = Completer();
      void handleFailRes() {
        if (!completer.isCompleted && failureCount == _ipInfoSources.length) {
          completer.complete(Result.success(null));
        }
      }

      final future = dio
          .get<Map<String, dynamic>>(
            source.key,
            cancelToken: token,
            options: Options(responseType: ResponseType.json),
          )
          .timeout(const Duration(seconds: 10));
      unawaited(
        future
            .then((res) {
              if (res.statusCode == HttpStatus.ok && res.data != null) {
                completer.complete(Result.success(source.value(res.data!)));
                return;
              }
              commonPrint.log('checkIp data empty', logLevel: LogLevel.info);
              failureCount++;
              handleFailRes();
            })
            .catchError((e) {
              failureCount++;
              if (e is DioException && e.type == DioExceptionType.cancel) {
                completer.complete(Result.error('cancelled'));
                return;
              }
              commonPrint.log('checkIp error $e', logLevel: LogLevel.warning);
              handleFailRes();
            }),
      );
      return completer.future;
    });
    final res = await Future.any(futures);
    token.cancel();
    return res;
  }
}

final request = Request();

String? getFileNameForDisposition(String? disposition) {
  if (disposition == null) return null;
  final parseValue = HeaderValue.parse(disposition);
  final parameters = parseValue.parameters;
  final fileNamePointKey = parameters.keys.firstWhere(
    (key) => key == 'filename*',
    orElse: () => '',
  );
  if (fileNamePointKey.isNotEmpty) {
    final res = parameters[fileNamePointKey]?.split("''") ?? [];
    if (res.length >= 2) {
      return Uri.decodeComponent(res[1]);
    }
  }
  final fileNameKey = parameters.keys.firstWhere(
    (key) => key == 'filename',
    orElse: () => '',
  );
  if (fileNameKey.isEmpty) return null;
  return parameters[fileNameKey];
}
