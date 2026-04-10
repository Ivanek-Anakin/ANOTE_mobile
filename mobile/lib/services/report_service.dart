import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config/constants.dart';

class ReportAuthException implements Exception {
  final String message;
  const ReportAuthException(this.message);
  @override
  String toString() => 'ReportAuthException: $message';
}

class ReportBadRequestException implements Exception {
  final String message;
  const ReportBadRequestException(this.message);
  @override
  String toString() => 'ReportBadRequestException: $message';
}

class ReportServerException implements Exception {
  final String message;
  const ReportServerException(this.message);
  @override
  String toString() => 'ReportServerException: $message';
}

class ReportNetworkException implements Exception {
  final String message;
  const ReportNetworkException(this.message);
  @override
  String toString() => 'ReportNetworkException: $message';
}

class ReportService {
  final Dio _dio;
  final FlutterSecureStorage _storage;

  ReportService({Dio? dio, FlutterSecureStorage? storage})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 120),
            )),
        _storage = storage ?? const FlutterSecureStorage();

  Future<String> _getBaseUrl() async {
    final url = await _storage.read(key: AppConstants.secureStorageKeyUrl);
    return url?.isNotEmpty == true ? url! : AppConstants.defaultBackendUrl;
  }

  Future<String?> _getToken() async {
    final token = await _storage.read(key: AppConstants.secureStorageKeyToken);
    return token?.isNotEmpty == true ? token : AppConstants.defaultToken;
  }

  /// Generate a structured medical report from a transcript.
  ///
  /// [visitType] is sent to the backend as `visit_type` to control prompt
  /// selection ("default", "initial", "followup").
  Future<String> generateReport(String transcript,
      {String visitType = 'default'}) async {
    final baseUrl = await _getBaseUrl();
    final token = await _getToken();

    try {
      final response = await _dio.post(
        '$baseUrl/report',
        data: {
          'transcript': transcript,
          'language': 'cs',
          'visit_type': visitType,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer ${token ?? ''}',
            'Content-Type': 'application/json',
          },
        ),
      );
      final report = response.data['report'] as String?;
      return report ?? '';
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      if (statusCode == 401) {
        throw const ReportAuthException('Invalid or missing API token');
      } else if (statusCode == 400) {
        throw const ReportBadRequestException('Empty or invalid transcript');
      } else if (statusCode == 502) {
        throw const ReportServerException('Backend server error');
      }
      // Provide user-friendly Czech message for network errors
      final msg = e.message?.toLowerCase() ?? '';
      if (msg.contains('connection closed') ||
          msg.contains('connection refused') ||
          msg.contains('socket') ||
          msg.contains('timed out') ||
          msg.contains('network')) {
        throw const ReportNetworkException(
            'Připojení k serveru selhalo. Zkontrolujte internet.');
      }
      throw ReportNetworkException('Chyba sítě: ${e.message}');
    }
  }

  /// Send a generated report to the configured email address.
  /// Fire-and-forget from the caller's perspective.
  Future<void> sendReportEmail({
    required String report,
    required String email,
    String visitType = 'default',
  }) async {
    final baseUrl = await _getBaseUrl();
    final token = await _getToken();

    await _dio.post(
      '$baseUrl/send-report-email',
      data: {
        'report': report,
        'email': email,
        'visit_type': visitType,
      },
      options: Options(
        headers: {
          'Authorization': 'Bearer ${token ?? ''}',
          'Content-Type': 'application/json',
        },
      ),
    );
  }

  /// Check if the backend is reachable.
  /// Retries up to 3 times with backoff to handle Azure cold starts.
  Future<bool> isBackendReachable() async {
    final baseUrl = await _getBaseUrl();
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final response = await _dio.get(
          '$baseUrl/health',
          options: Options(receiveTimeout: const Duration(seconds: 15)),
        );
        if (response.statusCode == 200) return true;
      } catch (_) {
        if (attempt < 3) {
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
    }
    return false;
  }
}
