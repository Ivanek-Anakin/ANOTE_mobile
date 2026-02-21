class AppConstants {
  static const String defaultBackendUrl =
      'https://anote-api.westeurope.azurecontainerapps.io';
  static const Duration reportGenerationInterval = Duration(seconds: 15);
  static const Duration pollInterval = Duration(milliseconds: 500);
  static const String secureStorageKeyToken = 'api_bearer_token';
  static const String secureStorageKeyUrl = 'backend_url';
}
