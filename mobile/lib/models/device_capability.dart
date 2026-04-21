import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// Turbo capability status for the current device.
enum TurboCapabilityStatus {
  /// Not yet determined.
  unknown,

  /// Device is known-good; Turbo allowed.
  allowed,

  /// Device may work but is not tested; proceed with caution.
  discouraged,

  /// Turbo is blocked (crash suspected or known-bad device).
  blocked,
}

/// Persistent device capability record for Turbo model support.
class DeviceCapability {
  final TurboCapabilityStatus turboStatus;
  final bool hybridPrefersTurbo;
  final bool previousTurboSuccess;
  final bool previousTurboCrashSuspected;
  final bool turboProbePending;
  final String? deviceModelIdentifier;
  final DateTime? lastEvaluatedAt;

  const DeviceCapability({
    this.turboStatus = TurboCapabilityStatus.unknown,
    this.hybridPrefersTurbo = false,
    this.previousTurboSuccess = false,
    this.previousTurboCrashSuspected = false,
    this.turboProbePending = false,
    this.deviceModelIdentifier,
    this.lastEvaluatedAt,
  });

  DeviceCapability copyWith({
    TurboCapabilityStatus? turboStatus,
    bool? hybridPrefersTurbo,
    bool? previousTurboSuccess,
    bool? previousTurboCrashSuspected,
    bool? turboProbePending,
    String? deviceModelIdentifier,
    DateTime? lastEvaluatedAt,
  }) {
    return DeviceCapability(
      turboStatus: turboStatus ?? this.turboStatus,
      hybridPrefersTurbo: hybridPrefersTurbo ?? this.hybridPrefersTurbo,
      previousTurboSuccess: previousTurboSuccess ?? this.previousTurboSuccess,
      previousTurboCrashSuspected:
          previousTurboCrashSuspected ?? this.previousTurboCrashSuspected,
      turboProbePending: turboProbePending ?? this.turboProbePending,
      deviceModelIdentifier:
          deviceModelIdentifier ?? this.deviceModelIdentifier,
      lastEvaluatedAt: lastEvaluatedAt ?? this.lastEvaluatedAt,
    );
  }

  /// Whether Turbo can be shown in the UI at all.
  bool get canShowTurbo =>
      turboStatus == TurboCapabilityStatus.allowed ||
      turboStatus == TurboCapabilityStatus.unknown ||
      turboStatus == TurboCapabilityStatus.discouraged;

  /// Whether Turbo can be actively used (not blocked).
  bool get canUseTurbo =>
      turboStatus == TurboCapabilityStatus.allowed ||
      turboStatus == TurboCapabilityStatus.discouraged ||
      turboStatus == TurboCapabilityStatus.unknown;

  /// Whether Hybrid mode should default to Turbo for local preview.
  bool get hybridShouldUseTurbo =>
      turboStatus == TurboCapabilityStatus.allowed && hybridPrefersTurbo;

  // -------------------------------------------------------------------------
  // Persistence keys
  // -------------------------------------------------------------------------

  static const String _keyTurboStatus = 'turbo_status';
  static const String _keyHybridPrefersTurbo = 'hybrid_prefers_turbo';
  static const String _keyPreviousTurboSuccess = 'turbo_probe_succeeded';
  static const String _keyPreviousTurboCrash = 'turbo_crash_suspected';
  static const String _keyTurboProbePending = 'turbo_probe_pending';
  static const String _keyDeviceModel = 'device_model_identifier';
  static const String _keyLastEvaluated = 'turbo_last_evaluated';

  /// Load persisted capability from SharedPreferences.
  static Future<DeviceCapability> load() async {
    final prefs = await SharedPreferences.getInstance();
    return DeviceCapability(
      turboStatus: _statusFromString(prefs.getString(_keyTurboStatus)),
      hybridPrefersTurbo: prefs.getBool(_keyHybridPrefersTurbo) ?? false,
      previousTurboSuccess: prefs.getBool(_keyPreviousTurboSuccess) ?? false,
      previousTurboCrashSuspected:
          prefs.getBool(_keyPreviousTurboCrash) ?? false,
      turboProbePending: prefs.getBool(_keyTurboProbePending) ?? false,
      deviceModelIdentifier: prefs.getString(_keyDeviceModel),
      lastEvaluatedAt: _dateFromMillis(prefs.getInt(_keyLastEvaluated)),
    );
  }

  /// Persist current state to SharedPreferences.
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyTurboStatus, turboStatus.name);
    await prefs.setBool(_keyHybridPrefersTurbo, hybridPrefersTurbo);
    await prefs.setBool(_keyPreviousTurboSuccess, previousTurboSuccess);
    await prefs.setBool(_keyPreviousTurboCrash, previousTurboCrashSuspected);
    await prefs.setBool(_keyTurboProbePending, turboProbePending);
    if (deviceModelIdentifier != null) {
      await prefs.setString(_keyDeviceModel, deviceModelIdentifier!);
    }
    if (lastEvaluatedAt != null) {
      await prefs.setInt(
          _keyLastEvaluated, lastEvaluatedAt!.millisecondsSinceEpoch);
    }
  }

  static TurboCapabilityStatus _statusFromString(String? value) {
    switch (value) {
      case 'allowed':
        return TurboCapabilityStatus.allowed;
      case 'discouraged':
        return TurboCapabilityStatus.discouraged;
      case 'blocked':
        return TurboCapabilityStatus.blocked;
      default:
        return TurboCapabilityStatus.unknown;
    }
  }

  static DateTime? _dateFromMillis(int? millis) {
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }
}

// ---------------------------------------------------------------------------
// Static policy resolver
// ---------------------------------------------------------------------------

class TurboCapabilityResolver {
  /// Known-good iOS device model identifiers (≥ 6 GB RAM, A15+).
  /// Format: iPhone{major},{minor} — from https://www.theiphonewiki.com
  static const Set<String> _knownGoodIosDevices = {
    // iPhone 15 Pro / Pro Max (A17 Pro, 8 GB)
    'iPhone16,1',
    'iPhone16,2',
    // iPhone 16 (A18, 8 GB)
    'iPhone17,3',
    'iPhone17,4',
    // iPhone 16 Pro / Pro Max (A18 Pro, 8 GB)
    'iPhone17,1',
    'iPhone17,2',
    // iPad Pro M1+ models (8+ GB) — conservative subset
    'iPad13,4',
    'iPad13,5',
    'iPad13,6',
    'iPad13,7',
    'iPad13,8',
    'iPad13,9',
    'iPad13,10',
    'iPad13,11',
    'iPad14,3',
    'iPad14,4',
    'iPad14,5',
    'iPad14,6',
    'iPad16,3',
    'iPad16,4',
    'iPad16,5',
    'iPad16,6',
  };

  /// Known-bad: devices that definitely cannot run Turbo safely.
  static const Set<String> _knownBadIosDevicePrefixes = {
    'iPhone10,', // iPhone X / 8 (3 GB)
    'iPhone11,', // iPhone XR / XS (3-4 GB)
    'iPhone12,', // iPhone 11 (4 GB)
  };

  /// Resolve device capability using policy table + persisted state.
  ///
  /// Call on app launch to determine Turbo availability.
  static Future<DeviceCapability> resolve({
    required String? deviceModelIdentifier,
  }) async {
    var capability = await DeviceCapability.load();

    // Check crash suspicion: if a probe was pending and never cleared,
    // the app likely crashed during a Turbo attempt.
    if (capability.turboProbePending && !capability.previousTurboSuccess) {
      capability = capability.copyWith(
        turboStatus: TurboCapabilityStatus.blocked,
        previousTurboCrashSuspected: true,
        turboProbePending: false,
        hybridPrefersTurbo: false,
        lastEvaluatedAt: DateTime.now(),
      );
      await capability.save();
      return capability;
    }

    // If already evaluated and has a definitive status, keep it.
    if (capability.turboStatus != TurboCapabilityStatus.unknown &&
        capability.lastEvaluatedAt != null) {
      // Update device model if newly discovered
      if (deviceModelIdentifier != null &&
          capability.deviceModelIdentifier != deviceModelIdentifier) {
        capability = capability.copyWith(
          deviceModelIdentifier: deviceModelIdentifier,
        );
        await capability.save();
      }
      return capability;
    }

    // --- First-time resolution from policy table ---
    final status = _resolveFromPolicy(deviceModelIdentifier);
    final hybridPrefersTurbo = status == TurboCapabilityStatus.allowed;

    capability = capability.copyWith(
      turboStatus: status,
      hybridPrefersTurbo: hybridPrefersTurbo,
      deviceModelIdentifier: deviceModelIdentifier,
      lastEvaluatedAt: DateTime.now(),
    );
    await capability.save();
    return capability;
  }

  /// Pure policy table lookup. No I/O.
  static TurboCapabilityStatus _resolveFromPolicy(String? deviceModel) {
    if (!Platform.isIOS) {
      // Android: allow Turbo if the device identifier is not null (heuristic).
      // The existing RAM-based check in session_provider handles Android.
      return TurboCapabilityStatus.allowed;
    }

    if (deviceModel == null || deviceModel.isEmpty) {
      return TurboCapabilityStatus.unknown;
    }

    // Check known-good list
    if (_knownGoodIosDevices.contains(deviceModel)) {
      return TurboCapabilityStatus.allowed;
    }

    // Check known-bad prefixes
    for (final prefix in _knownBadIosDevicePrefixes) {
      if (deviceModel.startsWith(prefix)) {
        return TurboCapabilityStatus.blocked;
      }
    }

    // iPhone 13 / 14 base models (4-6 GB) — discouraged
    if (deviceModel.startsWith('iPhone14,') ||
        deviceModel.startsWith('iPhone15,')) {
      // iPhone 14 Pro / Pro Max have identifiers iPhone15,2 and iPhone15,3
      // but iPhone15,2 is iPhone 14 Pro (6 GB) — still risky for Turbo.
      return TurboCapabilityStatus.discouraged;
    }

    // iPhone 13 mini/standard (iPhone14,4 / iPhone14,5) — 4 GB
    // Already caught by iPhone14, prefix above.

    return TurboCapabilityStatus.unknown;
  }
}
