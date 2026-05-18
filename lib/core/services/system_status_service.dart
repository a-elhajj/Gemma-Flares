import 'package:flutter/services.dart';

class SystemStatusSnapshot {
  const SystemStatusSnapshot({
    required this.lowPowerModeEnabled,
    required this.thermalState,
    required this.backgroundRefreshStatus,
    this.availableMemoryBytes,
  });

  final bool lowPowerModeEnabled;
  final String thermalState;
  final String backgroundRefreshStatus;
  final int? availableMemoryBytes;

  bool get shouldSkipRefreshForThermal {
    return thermalState == 'serious' || thermalState == 'critical';
  }

  bool get shouldAvoidModelGeneration {
    return lowPowerModeEnabled || shouldSkipRefreshForThermal;
  }

  Map<String, Object?> toJson() {
    return {
      'low_power_mode_enabled': lowPowerModeEnabled,
      'thermal_state': thermalState,
      'background_refresh_status': backgroundRefreshStatus,
      'available_memory_bytes': availableMemoryBytes,
    };
  }
}

abstract class SystemStatusService {
  Future<SystemStatusSnapshot> getStatus();
}

class MethodChannelSystemStatusService implements SystemStatusService {
  MethodChannelSystemStatusService({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('com.gemma_flares/system_status');

  final MethodChannel _channel;

  @override
  Future<SystemStatusSnapshot> getStatus() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getSystemStatus',
      );
      final map = raw ?? const <Object?, Object?>{};
      return SystemStatusSnapshot(
        lowPowerModeEnabled: map['lowPowerModeEnabled'] == true,
        thermalState: (map['thermalState'] as String? ?? 'unknown').trim(),
        availableMemoryBytes: _nullableIntFromJson(map['availableMemoryBytes']),
        backgroundRefreshStatus:
            (map['backgroundRefreshStatus'] as String? ?? 'unknown').trim(),
      );
    } catch (_) {
      return const SystemStatusSnapshot(
        lowPowerModeEnabled: false,
        thermalState: 'unknown',
        backgroundRefreshStatus: 'unknown',
      );
    }
  }
}

int? _nullableIntFromJson(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

class UnavailableSystemStatusService implements SystemStatusService {
  const UnavailableSystemStatusService();

  @override
  Future<SystemStatusSnapshot> getStatus() async {
    return const SystemStatusSnapshot(
      lowPowerModeEnabled: false,
      thermalState: 'unknown',
      backgroundRefreshStatus: 'unknown',
    );
  }
}
