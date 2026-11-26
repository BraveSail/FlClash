import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// Display name of the built-in Hub subscription.
const hubProfileLabel = 'Hub';

/// Optional build-time default. The runtime HUB_URL takes precedence.
const hubBaseUrl = String.fromEnvironment('HUB_URL');

/// Shared device key file stored in the app's home directory.
///
/// Format matches `core/Clash.Meta/component/mesh/keys.go` (`storedKeys`):
/// `{"transport": "<base64url-nopad>", "signing": "<base64url-nopad>"}`.
const meshKeyFileName = 'mesh-key.json';

const _deviceIdLength = 12;
const _seedLength = 32;

/// Resolved Hub configuration for a build.
class HubConfig {
  const HubConfig({required this.baseUri});

  factory HubConfig.fromStrings({required String url}) {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) {
      return const HubConfig(baseUri: null);
    }
    final parsed = Uri.tryParse(trimmedUrl);
    if (parsed == null ||
        (parsed.scheme != 'https' &&
            !(parsed.scheme == 'http' &&
                const {
                  '127.0.0.1',
                  '::1',
                  'localhost',
                }.contains(parsed.host))) ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      return const HubConfig(baseUri: null);
    }
    return HubConfig(baseUri: parsed);
  }

  final Uri? baseUri;

  bool get isConfigured => baseUri != null;

  String get _normalizedBasePath {
    final raw = baseUri!.path;
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  String get profilePath => '$_normalizedBasePath/profile';

  String get watchPath => '$_normalizedBasePath/profile/watch';

  Uri get registerUri =>
      baseUri!.replace(path: '$_normalizedBasePath/register');

  Uri profileUri(String deviceId) {
    final base = baseUri!;
    return base.replace(path: profilePath, queryParameters: {'id': deviceId});
  }

  Uri watchUri(String deviceId) {
    final base = baseUri!;
    final wsScheme = base.scheme == 'https' ? 'wss' : 'ws';
    return base.replace(
      scheme: wsScheme,
      path: watchPath,
      queryParameters: {'id': deviceId},
    );
  }

  /// Whether [uri] targets this Hub's origin (HTTP/HTTPS/WS/WSS).
  bool matchesOrigin(Uri uri) {
    final base = baseUri;
    if (base == null) return false;
    final expectedWs = base.scheme == 'https' ? 'wss' : 'ws';
    final schemeMatches = uri.scheme == base.scheme || uri.scheme == expectedWs;
    return schemeMatches &&
        uri.host.toLowerCase() == base.host.toLowerCase() &&
        _effectivePort(uri) == _effectivePort(base);
  }

  /// Whether [profile] is the built-in Hub subscription for this build.
  bool isHubProfile(Profile profile) {
    if (!isConfigured ||
        profile.type != ProfileType.url ||
        profile.url.isEmpty) {
      return false;
    }
    final uri = Uri.tryParse(profile.url);
    if (uri == null) return false;
    if (uri.path != profilePath || uri.userInfo.isNotEmpty) return false;
    if (matchesOrigin(uri)) return true;
    return profile.label == hubProfileLabel &&
        baseUri!.scheme == 'https' &&
        uri.scheme == 'http' &&
        _effectivePort(uri) == 80 &&
        uri.host.toLowerCase() == baseUri!.host.toLowerCase();
  }
}

final HubConfig _buildHubConfig = HubConfig.fromStrings(
  url: Platform.environment['HUB_URL'] ?? hubBaseUrl,
);

@visibleForTesting
HubConfig? debugHubConfigOverride;

HubConfig get defaultHubConfig => debugHubConfigOverride ?? _buildHubConfig;

bool get isHubConfigured => defaultHubConfig.isConfigured;

bool isHubProfile(Profile profile) => defaultHubConfig.isHubProfile(profile);

bool isHubRequestUri(Uri uri) => defaultHubConfig.matchesOrigin(uri);

/// Derives the 12-hex-char device ID from a 32-byte Ed25519 signing seed:
/// `sha256("key:" || ed25519_public_key)` -> lowercase hex -> first 12 chars.
///
/// Mirrors `component/mesh/identity.go:DeriveOn`.
Future<String> deriveDeviceIdFromSeed(List<int> signingSeed) async {
  if (signingSeed.length != _seedLength) {
    throw ArgumentError.value(
      signingSeed.length,
      'signingSeed.length',
      'Ed25519 seed must be $_seedLength bytes',
    );
  }
  final keyPair = await Ed25519().newKeyPairFromSeed(signingSeed);
  final publicKey = await keyPair.extractPublicKey();
  final digest = await Sha256().hash([
    ...utf8.encode('key:'),
    ...publicKey.bytes,
  ]);
  final buffer = StringBuffer();
  for (final byte in digest.bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString().substring(0, _deviceIdLength);
}

/// Loads `mesh-key.json` from [homeDir] (or `appPath.homeDirPath`), creating
/// one atomically if absent, and returns the derived 12-char device ID.
///
/// Because the app owns key creation and reads the exact same file format that
/// `component/mesh/keys.go` uses, the app never waits on or races the core for
/// its device identity.
Future<String> loadOrCreateMeshDeviceId({String? homeDir}) async =>
    (await loadOrCreateHubIdentity(homeDir: homeDir)).deviceId;

/// A local signing key; only its public key and signatures go to the Hub.
class HubIdentity {
  const HubIdentity._(this.deviceId, this._signingSeed);

  final String deviceId;
  final List<int> _signingSeed;

  Future<String> publicKey() async {
    final pair = await Ed25519().newKeyPairFromSeed(_signingSeed);
    return _encodeBase64UrlNoPad((await pair.extractPublicKey()).bytes);
  }

  Future<Map<String, String>> signGet(Uri uri, {DateTime? now}) async {
    final timestamp = ((now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000)
        .toString();
    const emptyDigest =
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
    final message = utf8.encode(
      ['GET', uri.path, timestamp, emptyDigest, deviceId].join('\n'),
    );
    final algorithm = Ed25519();
    final signature = await algorithm.sign(
      message,
      keyPair: await algorithm.newKeyPairFromSeed(_signingSeed),
    );
    return {
      'x-mesh-id': deviceId,
      'x-mesh-timestamp': timestamp,
      'x-mesh-signature': _encodeBase64UrlNoPad(signature.bytes),
    };
  }
}

Future<HubIdentity> _identityFromSeed(List<int> seed) async =>
    HubIdentity._(await deriveDeviceIdFromSeed(seed), seed);

Future<HubIdentity> loadOrCreateHubIdentity({String? homeDir}) async {
  final dir = homeDir ?? await appPath.homeDirPath;
  final keyFile = File(p.join(dir, meshKeyFileName));

  if (await keyFile.exists()) {
    final raw = await keyFile.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('mesh-key.json is not a JSON object');
    }
    final signing = decoded['signing'];
    if (signing is! String || signing.isEmpty) {
      throw const FormatException('mesh-key.json is missing signing key');
    }
    final seed = _decodeBase64Url(signing);
    if (seed.length != _seedLength) {
      throw const FormatException('mesh-key.json signing key must be 32 bytes');
    }
    return _identityFromSeed(seed);
  }

  final random = Random.secure();
  final transportSeed = List<int>.generate(
    _seedLength,
    (_) => random.nextInt(256),
  );
  final signingSeed = List<int>.generate(
    _seedLength,
    (_) => random.nextInt(256),
  );

  final payload = const JsonEncoder.withIndent('  ').convert({
    'transport': _encodeBase64UrlNoPad(transportSeed),
    'signing': _encodeBase64UrlNoPad(signingSeed),
  });

  await Directory(dir).create(recursive: true);
  final tempFile = File(p.join(dir, '$meshKeyFileName.tmp.$pid'));
  try {
    await tempFile.writeAsString(payload, flush: true);
    await tempFile.rename(keyFile.path);
  } catch (_) {
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
    rethrow;
  }

  return _identityFromSeed(signingSeed);
}

String _encodeBase64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> _decodeBase64Url(String value) {
  final padding = (4 - value.length % 4) % 4;
  return base64Url.decode('$value${'=' * padding}');
}

int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return switch (uri.scheme) {
    'http' || 'ws' => 80,
    'https' || 'wss' => 443,
    _ => uri.port,
  };
}
