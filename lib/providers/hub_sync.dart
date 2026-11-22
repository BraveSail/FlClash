import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _hubPollInterval = Duration(minutes: 5);
const _hubFetchTimeout = Duration(seconds: 20);
const _hubResumeMinInterval = Duration(seconds: 30);
const _hubFreshnessWindow = Duration(seconds: 30);
const _hubWatchPingInterval = Duration(seconds: 45);
const _hubWatchRetryFloor = Duration(seconds: 2);
const _hubWatchRetryCeiling = Duration(minutes: 2);
const _hubWatchHealthyDuration = Duration(seconds: 15);
const _hubMaxProfileBytes = 4 << 20;

/// Manages passive background updates (WebSocket push + periodic ETag poll)
/// for the built-in Hub subscription on Windows and Android.
///
/// The core never pulls from the Hub in app mode; this controller is the sole
/// passive updater, validating every pulled YAML through the core and only
/// reloading the core when the built-in Hub profile is currently active.
class HubSync extends Notifier<bool> {
  HubConfig _config = defaultHubConfig;
  String? _deviceId;
  String? _etag;
  int _generation = 0;
  Timer? _pollTimer;
  WebSocket? _activeSocket;
  DateTime? _lastPollAttempt;
  Future<bool>? _pollInFlight;
  Future<void> _commitQueue = Future<void>.value();
  bool _disposed = false;

  @override
  bool build() {
    ref.onDispose(() {
      _disposed = true;
      stop();
    });
    return false;
  }

  /// Starts passive sync for [deviceId]. Idempotent if already running for the
  /// same device and Hub configuration.
  void start({required String deviceId, HubConfig? config}) {
    final effectiveConfig = config ?? defaultHubConfig;
    if (!effectiveConfig.isConfigured || deviceId.isEmpty) {
      return;
    }
    if (state && _deviceId == deviceId && _config == effectiveConfig) {
      return;
    }
    stop();
    _config = effectiveConfig;
    _deviceId = deviceId;
    _etag = null;
    final generation = ++_generation;
    state = true;

    _pollTimer = Timer.periodic(_hubPollInterval, (_) {
      unawaited(pollOnce());
    });
    unawaited(_watchLoop(generation));
    unawaited(_initialSyncIfStale());
  }

  /// Stops all passive sync timers and closes any open watch socket.
  void stop() {
    _generation++;
    _pollTimer?.cancel();
    _pollTimer = null;
    final socket = _activeSocket;
    _activeSocket = null;
    if (socket != null) {
      unawaited(socket.close().catchError((Object _) {}));
    }
    if (!_disposed && state) {
      state = false;
    }
  }

  /// Called when the app returns to foreground (e.g. Android wake / resume).
  void onAppResumed() {
    if (!state || _deviceId == null) return;
    final last = _lastPollAttempt;
    if (last != null &&
        DateTime.now().difference(last) < _hubResumeMinInterval) {
      return;
    }
    unawaited(pollOnce());
  }

  Future<void> _initialSyncIfStale() async {
    final hub = _findHubProfile();
    if (hub == null) return;
    final profileFile = File(await appPath.getProfilePath(hub.id.toString()));
    final exists = await profileFile.exists();
    final lastUpdate = hub.lastUpdateDate;
    final isFresh =
        exists &&
        lastUpdate != null &&
        DateTime.now().difference(lastUpdate) < _hubFreshnessWindow;
    if (!isFresh) {
      await pollOnce();
    }
  }

  /// Performs a single conditional HTTP poll (`If-None-Match`) against the Hub.
  /// Returns `true` if the profile content changed and was committed.
  Future<bool> pollOnce() {
    final existing = _pollInFlight;
    if (existing != null) return existing;
    final task = _doPoll();
    _pollInFlight = task;
    return task.whenComplete(() {
      if (identical(_pollInFlight, task)) {
        _pollInFlight = null;
      }
    });
  }

  Future<bool> _doPoll() async {
    final deviceId = _deviceId;
    if (_disposed || !state || deviceId == null || !_config.isConfigured) {
      return false;
    }
    _lastPollAttempt = DateTime.now();
    final uri = _config.profileUri(deviceId);
    final client = _createDirectClient();
    try {
      final request = await client.getUrl(uri).timeout(_hubFetchTimeout);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${_config.token}',
      );
      final etag = _etag;
      if (etag != null && etag.isNotEmpty) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }
      final response = await request.close().timeout(_hubFetchTimeout);
      if (response.statusCode == HttpStatus.notModified) {
        await response.drain<void>();
        return false;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        commonPrint.log(
          'hubSync poll returned HTTP ${response.statusCode}',
          logLevel: LogLevel.warning,
        );
        return false;
      }
      final bytes = await _readBoundedBytes(response, _hubMaxProfileBytes);
      if (bytes == null || bytes.isEmpty) {
        return false;
      }
      final responseEtag = response.headers
          .value(HttpHeaders.etagHeader)
          ?.trim();
      final changed = await _enqueueCommit(bytes);
      if (responseEtag != null && responseEtag.isNotEmpty) {
        _etag = responseEtag;
      }
      return changed;
    } catch (error) {
      commonPrint.log(
        'hubSync poll error: ${compactError(error)}',
        logLevel: LogLevel.warning,
      );
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _watchLoop(int generation) async {
    var backoff = _hubWatchRetryFloor;
    while (!_disposed && generation == _generation) {
      final deviceId = _deviceId;
      if (deviceId == null || !_config.isConfigured) return;

      final uri = _config.watchUri(deviceId);
      final client = _createDirectClient();
      final connectedAt = DateTime.now();
      var receivedValidMessage = false;
      WebSocket? socket;
      try {
        socket = await WebSocket.connect(
          uri.toString(),
          headers: {HttpHeaders.authorizationHeader: 'Bearer ${_config.token}'},
          customClient: client,
        ).timeout(_hubFetchTimeout);
        if (_disposed || generation != _generation) {
          await socket.close();
          return;
        }
        socket.pingInterval = _hubWatchPingInterval;
        _activeSocket = socket;

        await for (final message in socket) {
          if (_disposed || generation != _generation) {
            break;
          }
          if (await _handleWatchMessage(message)) {
            receivedValidMessage = true;
          }
        }
      } catch (error) {
        if (!_disposed && generation == _generation) {
          commonPrint.log(
            'hubSync watch ended: ${compactError(error)}',
            logLevel: LogLevel.debug,
          );
        }
      } finally {
        if (identical(_activeSocket, socket)) {
          _activeSocket = null;
        }
        if (socket != null) {
          unawaited(socket.close().catchError((Object _) {}));
        }
        client.close(force: true);
      }

      if (_disposed || generation != _generation) {
        return;
      }
      final healthy =
          receivedValidMessage ||
          DateTime.now().difference(connectedAt) >= _hubWatchHealthyDuration;
      if (healthy) {
        backoff = _hubWatchRetryFloor;
      } else {
        final nextMs = backoff.inMilliseconds * 2;
        backoff = Duration(
          milliseconds: nextMs > _hubWatchRetryCeiling.inMilliseconds
              ? _hubWatchRetryCeiling.inMilliseconds
              : nextMs,
        );
      }
      await Future<void>.delayed(backoff);
    }
  }

  Future<bool> _handleWatchMessage(Object? message) async {
    final String text;
    if (message is String) {
      text = message;
    } else if (message is List<int>) {
      text = utf8.decode(message, allowMalformed: true);
    } else {
      return false;
    }
    if (text.isEmpty) return false;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return false;
      if (decoded['type'] != 'profile') return false;
      final yaml = decoded['yaml'];
      if (yaml is! String || yaml.trim().isEmpty) return false;
      final etag = (decoded['etag'] as String?)?.trim();
      if (etag != null && etag.isNotEmpty && etag == _etag) {
        return true;
      }
      final bytes = Uint8List.fromList(utf8.encode(yaml));
      await _enqueueCommit(bytes);
      if (etag != null && etag.isNotEmpty) {
        _etag = etag;
      }
      return true;
    } catch (error) {
      commonPrint.log(
        'hubSync watch message ignored: ${compactError(error)}',
        logLevel: LogLevel.debug,
      );
      return false;
    }
  }

  Future<bool> _enqueueCommit(Uint8List bytes) {
    final completer = Completer<bool>();
    _commitQueue = _commitQueue.then((_) async {
      try {
        completer.complete(await _commitYamlBytes(bytes));
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<bool> _commitYamlBytes(Uint8List bytes) async {
    if (_disposed) return false;
    final deviceId = _deviceId;
    if (deviceId == null) return false;
    final hub = _findHubProfile();
    if (hub == null) return false;

    final filePath = await appPath.getProfilePath(hub.id.toString());
    final file = File(filePath);
    if (await file.exists()) {
      final existing = await file.readAsBytes();
      if (_bytesEqual(existing, bytes)) {
        return false;
      }
    }

    final core = ref.read(coreHandlerProvider);
    final saved = await hub.saveFile(
      bytes,
      validate: (path, key) => core.validateProfile(path, key),
    );
    if (_disposed) return false;

    final latest = ref.read(profilesProvider).getProfile(hub.id);
    if (latest == null) return false;

    final canonicalUrl = _config.profileUri(deviceId).toString();
    ref
        .read(profilesProvider.notifier)
        .put(
          latest.copyWith(
            label: hubProfileLabel,
            url: canonicalUrl,
            autoUpdate: true,
            lastUpdateDate: saved.lastUpdateDate,
          ),
        );

    if (ref.read(currentProfileIdProvider) == latest.id) {
      ref
          .read(setupActionProvider.notifier)
          .applyProfileDebounce(silence: true);
    }
    return true;
  }

  Profile? _findHubProfile() {
    final profiles = ref.read(profilesProvider);
    final currentId = ref.read(currentProfileIdProvider);
    Profile? fallback;
    for (final profile in profiles) {
      if (!_config.isHubProfile(profile)) continue;
      if (profile.id == currentId) return profile;
      fallback ??= profile;
    }
    return fallback;
  }

  HttpClient _createDirectClient() {
    final client = HttpClient()
      ..connectionTimeout = _hubFetchTimeout
      ..findProxy = (_) => 'DIRECT';
    return client;
  }
}

final hubSyncProvider = NotifierProvider<HubSync, bool>(HubSync.new);

Future<Uint8List?> _readBoundedBytes(
  HttpClientResponse response,
  int maxBytes,
) async {
  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in response) {
    total += chunk.length;
    if (total > maxBytes) {
      return null;
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
