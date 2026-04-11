import 'dart:io';

import 'package:flutter/services.dart';

/// Queries native platform for device model identifier and memory info.
///
/// On iOS this uses a MethodChannel bridge to obtain the machine identifier
/// (e.g. "iPhone16,1") and total physical memory.
/// On Android or unsupported platforms, returns null / estimates.
class DeviceInfoService {
  static const _channel = MethodChannel('com.anote/device_info');

  /// Cached model identifier to avoid repeated native calls.
  static String? _cachedModel;

  /// Returns the iOS machine identifier (e.g. "iPhone16,1") or null on
  /// non-iOS platforms or on error.
  static Future<String?> getDeviceModelIdentifier() async {
    if (_cachedModel != null) return _cachedModel;
    if (!Platform.isIOS) return null;
    try {
      final String? model =
          await _channel.invokeMethod<String>('getDeviceModel');
      _cachedModel = model;
      return model;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Returns total physical memory in MB on iOS, or null on other platforms.
  static Future<int?> getTotalMemoryMB() async {
    if (!Platform.isIOS) return null;
    try {
      final int? mb = await _channel.invokeMethod<int>('getTotalMemoryMB');
      return mb;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
