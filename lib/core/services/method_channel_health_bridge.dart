import 'package:flutter/services.dart';

import '../contracts/health_bridge_contracts.dart';
import 'health_bridge.dart';

class MethodChannelHealthBridge implements HealthBridge {
  MethodChannelHealthBridge({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('com.gemma_flares/health_bridge');

  final MethodChannel _channel;

  @override
  Future<AuthorizationStatusResponse> getAuthorizationStatus(
    AuthorizationStatusRequest request,
  ) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'getAuthorizationStatus',
      request.toJson(),
    );
    return AuthorizationStatusResponse.fromJson(raw ?? const {});
  }

  @override
  Future<RequestAuthorizationResponse> requestAuthorization(
    List<HealthMetricType> readTypes,
  ) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'requestAuthorization',
      {'readTypes': readTypes.map((metric) => metric.wireName).toList()},
    );
    return RequestAuthorizationResponse.fromJson(raw ?? const {});
  }

  @override
  Future<FetchSamplesResponse> fetchSamples(FetchSamplesRequest request) async {
    final raw = await _channel.invokeMapMethod<Object?, Object?>(
      'fetchSamples',
      request.toJson(),
    );
    return FetchSamplesResponse.fromJson(raw ?? const {});
  }
}
