class AppConstants {
  // Production: Azure Container Apps (West Europe)
  static const String defaultBackendUrl =
      'https://anote-api.politesmoke-02c93984.westeurope.azurecontainerapps.io';
  static const String defaultToken =
      '_lZNhJDgaoneVaztSf2tJnf-rZMEQV5ZCLBPRAyC38I';
  static const Duration reportGenerationInterval = Duration(seconds: 15);
  static const Duration pollInterval = Duration(milliseconds: 500);
  static const String secureStorageKeyToken = 'api_bearer_token';
  static const String secureStorageKeyUrl = 'backend_url';
  static const String visitTypePrefKey = 'visit_type';
  static const String transcriptionModelPrefKey = 'transcription_model';
  static const String secureStorageKeyAzureWhisperUrl = 'azure_whisper_url';
  static const String secureStorageKeyAzureWhisperKey = 'azure_whisper_key';

  // Azure OpenAI Whisper (cloud transcription)
  static const String defaultAzureWhisperUrl =
      'https://anote-openai.openai.azure.com/openai/deployments/whisper/audio/transcriptions?api-version=2024-06-01';
  static const String defaultAzureWhisperKey =
      'REDACTED_KEY';
}
