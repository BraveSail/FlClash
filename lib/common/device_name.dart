import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/foundation.dart';

/// A phone's kernel host name is "localhost" and an app cannot change it, so
/// the name the owner typed has to come from here.
@visibleForTesting
String deviceName(
  String? androidName,
  String androidBrand,
  String androidModel,
  String desktopName,
) {
  final name = (androidName ?? '').trim();
  if (name.isNotEmpty) {
    return name;
  }
  final made = [
    androidBrand,
    androidModel,
  ].map((part) => part.trim()).where((part) => part.isNotEmpty).join(' ');
  if (made.isNotEmpty) {
    return made;
  }
  return desktopName.trim();
}

@visibleForTesting
String deviceOs(String name, String version, {String flavour = ''}) {
  final parts = [
    name.trim(),
    version.trim(),
    flavour.trim(),
  ].where((part) => part.isNotEmpty);
  return parts.join(' ');
}

Future<String>? _cachedName;

Future<String>? _cachedOs;

Future<String> hubDeviceName() {
  return _cachedName ??= _readDeviceName();
}

Future<String> hubDeviceOs() {
  return _cachedOs ??= _readDeviceOs();
}

Future<String> _readDeviceName() async {
  try {
    final deviceInfo = DeviceInfoPlugin();
    if (system.isAndroid) {
      final android = await deviceInfo.androidInfo;
      return deviceName(android.name, android.brand, android.model, '');
    }
    if (system.isWindows) {
      return deviceName(
        null,
        '',
        '',
        (await deviceInfo.windowsInfo).computerName,
      );
    }
    if (system.isMacOS) {
      return deviceName(
        null,
        '',
        '',
        (await deviceInfo.macOsInfo).computerName,
      );
    }
    // Linux already reports a useful host name through the kernel.
    return '';
  } catch (error) {
    commonPrint.log(
      'Failed to read the device name: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
    return '';
  }
}

Future<String> _readDeviceOs() async {
  try {
    final deviceInfo = DeviceInfoPlugin();
    if (system.isAndroid) {
      final android = await deviceInfo.androidInfo;
      return deviceOs('Android', android.version.release);
    }
    if (system.isWindows) {
      final windows = await deviceInfo.windowsInfo;
      // Both 10 and 11 report major version 10; the build number is what
      // tells them apart, and displayVersion ("24H2") when it is there.
      final eleven = windows.buildNumber >= 22000;
      final version = eleven
          ? '11'
          : '${windows.majorVersion}.${windows.minorVersion}';
      return deviceOs('Windows', version, flavour: windows.displayVersion);
    }
    if (system.isMacOS) {
      final macos = await deviceInfo.macOsInfo;
      return deviceOs(
        'macOS',
        '${macos.majorVersion}.${macos.minorVersion}.${macos.patchVersion}',
      );
    }
    final linux = await deviceInfo.linuxInfo;
    return deviceOs(linux.prettyName, '');
  } catch (error) {
    commonPrint.log(
      'Failed to read the system version: ${compactError(error)}',
      logLevel: LogLevel.warning,
    );
    return '';
  }
}

@visibleForTesting
void resetDeviceNameCache() {
  _cachedName = null;
  _cachedOs = null;
}
