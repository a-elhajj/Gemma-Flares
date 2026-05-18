import '../contracts/health_bridge_contracts.dart';

abstract class HealthBridge {
  Future<AuthorizationStatusResponse> getAuthorizationStatus(
    AuthorizationStatusRequest request,
  );

  Future<RequestAuthorizationResponse> requestAuthorization(
    List<HealthMetricType> readTypes,
  );

  Future<FetchSamplesResponse> fetchSamples(FetchSamplesRequest request);
}
