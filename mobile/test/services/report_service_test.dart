import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:anote_mobile/services/report_service.dart';

import 'report_service_test.mocks.dart';

@GenerateMocks([Dio, FlutterSecureStorage])
void main() {
  late MockDio mockDio;
  late MockFlutterSecureStorage mockStorage;
  late ReportService service;

  setUp(() {
    mockDio = MockDio();
    mockStorage = MockFlutterSecureStorage();
    service = ReportService(dio: mockDio, storage: mockStorage);

    when(mockStorage.read(key: anyNamed('key')))
        .thenAnswer((_) async => null);
  });

  group('generateReport', () {
    test('returns report on 200 response', () async {
      final response = Response(
        requestOptions: RequestOptions(path: '/report'),
        statusCode: 200,
        data: {'report': 'Strukturovaná lékařská zpráva...'},
      );

      when(mockDio.post(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => response);

      final result = await service.generateReport('Pacient přišel s bolestí hlavy.');
      expect(result, 'Strukturovaná lékařská zpráva...');
    });

    test('throws ReportAuthException on 401', () async {
      when(mockDio.post(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/report'),
        response: Response(
          requestOptions: RequestOptions(path: '/report'),
          statusCode: 401,
        ),
        type: DioExceptionType.badResponse,
      ));

      expect(
        () => service.generateReport('test transcript'),
        throwsA(isA<ReportAuthException>()),
      );
    });

    test('throws ReportServerException on 502', () async {
      when(mockDio.post(
        any,
        data: anyNamed('data'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/report'),
        response: Response(
          requestOptions: RequestOptions(path: '/report'),
          statusCode: 502,
        ),
        type: DioExceptionType.badResponse,
      ));

      expect(
        () => service.generateReport('test transcript'),
        throwsA(isA<ReportServerException>()),
      );
    });
  });

  group('isBackendReachable', () {
    test('returns true when health endpoint returns 200', () async {
      final response = Response(
        requestOptions: RequestOptions(path: '/health'),
        statusCode: 200,
        data: {'status': 'ok'},
      );

      when(mockDio.get(any)).thenAnswer((_) async => response);

      final result = await service.isBackendReachable();
      expect(result, isTrue);
    });

    test('returns false when health endpoint throws', () async {
      when(mockDio.get(any)).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/health'),
          type: DioExceptionType.connectionError,
        ),
      );

      final result = await service.isBackendReachable();
      expect(result, isFalse);
    });
  });
}
