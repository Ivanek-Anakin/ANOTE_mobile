class AppConstants {
  // Local dev: http://localhost:8000 (Chrome) or http://<mac-lan-ip>:8000 (phone)
  static const String defaultBackendUrl = 'http://172.20.10.2:8000';
  static const String defaultToken = 'dev-token';
  static const Duration reportGenerationInterval = Duration(seconds: 15);
  static const Duration pollInterval = Duration(milliseconds: 500);
  static const String secureStorageKeyToken = 'api_bearer_token';
  static const String secureStorageKeyUrl = 'backend_url';
}
