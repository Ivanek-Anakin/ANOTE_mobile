import 'secrets.dart';

class AppConstants {
  // Production: Azure Container Apps (West Europe)
  static const String defaultBackendUrl =
      'https://anote-api.politesmoke-02c93984.westeurope.azurecontainerapps.io';
  static const String defaultToken =
      '_lZNhJDgaoneVaztSf2tJnf-rZMEQV5ZCLBPRAyC38I';
  static const Duration reportGenerationInterval = Duration(seconds: 30);
  static const Duration pollInterval = Duration(milliseconds: 500);
  static const String secureStorageKeyToken = 'api_bearer_token';
  static const String secureStorageKeyUrl = 'backend_url';
  static const String visitTypePrefKey = 'visit_type';
  static const String transcriptionModelPrefKey = 'transcription_model';
  static const String secureStorageKeyAzureWhisperUrl = 'azure_whisper_url';
  static const String secureStorageKeyAzureWhisperKey = 'azure_whisper_key';

  // Email report settings
  static const String emailReportEnabledPrefKey = 'email_report_enabled';
  static const String emailReportAddressPrefKey = 'email_report_address';

  // Azure OpenAI cloud transcription (gpt-4o-mini-transcribe, Sweden Central)
  static const String defaultAzureWhisperUrl =
      'https://anote-openai-swe.openai.azure.com/openai/deployments/gpt-4o-mini-transcribe/audio/transcriptions?api-version=2024-06-01';
  static const String defaultAzureWhisperKey = Secrets.azureWhisperKey;
}
