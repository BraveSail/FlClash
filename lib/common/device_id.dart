import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:flutter/foundation.dart';

const _deviceIdLength = 12;

/// The id this device reports to the peer directory: its machine id hashed so
/// the raw one stays local, truncated to a DNS-safe label. The platform names
/// match what mihomo reports as its own platform.
@visibleForTesting
String deviceIdFrom(String platform, String machineId) {
  if (machineId.isEmpty) {
    return '';
  }
  final digest = sha256.convert(utf8.encode('$platform:$machineId'));
  return digest.toString().substring(0, _deviceIdLength);
}

Future<String>? _cached;

Future<String> deviceId() {
  return _cached ??= _computeDeviceId();
}

Future<String> _computeDeviceId() async {
  try {
    final platform = system.isAndroid
        ? 'android'
        : system.isWindows
        ? 'windows'
        : system.isMacOS
        ? 'darwin'
        : 'linux';
    final machineId = await _machineId();
    return deviceIdFrom(platform, machineId);
  } catch (error) {
    commonPrint.log(
      'Failed to compute the device id: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
    return '';
  }
}

Future<String> _machineId() async {
  if (system.isAndroid) {
    return await app?.getAndroidId() ?? '';
  }
  final deviceInfo = DeviceInfoPlugin();
  if (system.isWindows) {
    return (await deviceInfo.windowsInfo).deviceId;
  }
  if (system.isMacOS) {
    return (await deviceInfo.macOsInfo).systemGUID ?? '';
  }
  return (await deviceInfo.linuxInfo).machineId ?? '';
}

@visibleForTesting
void resetDeviceIdCache() {
  _cached = null;
}
