import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anote_mobile/services/cloud_transcription_service.dart';

/// Fake HttpClient that captures the request and returns a canned response.
class _FakeHttpClient implements HttpClient {
  final int statusCode;
  final String responseBody;
  _CapturedRequest? capturedRequest;

  _FakeHttpClient({
    this.statusCode = 200,
    this.responseBody = '{"text": "test transcript"}',
  });

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    final request = _CapturedRequest(url, statusCode, responseBody);
    capturedRequest = request;
    return request;
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _CapturedRequest implements HttpClientRequest {
  final Uri requestUri;
  final int _statusCode;
  final String _responseBody;
  final Map<String, String> capturedHeaders = {};
  final List<int> capturedBody = [];

  _CapturedRequest(this.requestUri, this._statusCode, this._responseBody);

  @override
  set contentLength(int length) {}

  @override
  HttpHeaders get headers => _FakeHeaders(capturedHeaders);

  @override
  void add(List<int> data) {
    capturedBody.addAll(data);
  }

  @override
  Future<HttpClientResponse> close() async {
    return _FakeResponse(_statusCode, _responseBody);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, String> _store;
  _FakeHeaders(this._store);

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _store[name] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A fake HttpClientResponse that works as a proper Stream<List<int>>.
class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  final int statusCode;
  final String _body;

  _FakeResponse(this.statusCode, this._body);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream.value(utf8.encode(_body)).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Fake FlutterSecureStorage that reads from an in-memory map.
class _FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String?> _store;
  _FakeSecureStorage(this._store);

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store[key];
}

void main() {
  group('CloudTranscriptionService', () {
    test('sends correct headers and body format', () async {
      final fakeClient = _FakeHttpClient();
      final fakeStorage = _FakeSecureStorage({
        'azure_whisper_url': 'https://test.openai.azure.com/openai/deployments/whisper/audio/transcriptions?api-version=2024-06-01',
        'azure_whisper_key': 'test-api-key-123',
      });

      final service = CloudTranscriptionService(
        storage: fakeStorage,
        httpClientFactory: () => fakeClient,
      );

      final samples = List<double>.filled(16000, 0.5); // 1s of audio
      final result = await service.transcribe(samples);

      expect(result, 'test transcript');
      expect(fakeClient.capturedRequest, isNotNull);
      expect(fakeClient.capturedRequest!.capturedHeaders['api-key'], 'test-api-key-123');
      expect(
        fakeClient.capturedRequest!.capturedHeaders['Content-Type'],
        contains('multipart/form-data'),
      );

      // Verify body contains WAV header (RIFF)
      final body = fakeClient.capturedRequest!.capturedBody;
      final bodyStr = String.fromCharCodes(body);
      expect(bodyStr, contains('RIFF'));
      expect(bodyStr, contains('audio.wav'));
      expect(bodyStr, contains('language'));
      expect(bodyStr, contains('cs'));
      expect(bodyStr, contains('response_format'));
      expect(bodyStr, contains('json'));
    });

    test('throws when Azure URL is not configured', () async {
      final fakeStorage = _FakeSecureStorage({
        'azure_whisper_url': '',
        'azure_whisper_key': 'some-key',
      });

      final service = CloudTranscriptionService(
        storage: fakeStorage,
        httpClientFactory: () => _FakeHttpClient(),
      );

      expect(
        () => service.transcribe([0.0, 0.1]),
        throwsA(isA<Exception>()),
      );
    });

    test('throws when Azure API key is not configured', () async {
      final fakeStorage = _FakeSecureStorage({
        'azure_whisper_url': 'https://test.openai.azure.com/test',
        'azure_whisper_key': '',
      });

      final service = CloudTranscriptionService(
        storage: fakeStorage,
        httpClientFactory: () => _FakeHttpClient(),
      );

      expect(
        () => service.transcribe([0.0, 0.1]),
        throwsA(isA<Exception>()),
      );
    });

    test('throws on non-2xx response', () async {
      final fakeStorage = _FakeSecureStorage({
        'azure_whisper_url': 'https://test.openai.azure.com/test',
        'azure_whisper_key': 'key',
      });

      final service = CloudTranscriptionService(
        storage: fakeStorage,
        httpClientFactory: () => _FakeHttpClient(
          statusCode: 500,
          responseBody: '{"error": "internal"}',
        ),
      );

      expect(
        () => service.transcribe([0.0, 0.1]),
        throwsA(isA<Exception>()),
      );
    });

    test('encodes WAV with correct sample rate', () async {
      final fakeClient = _FakeHttpClient();
      final fakeStorage = _FakeSecureStorage({
        'azure_whisper_url': 'https://test.openai.azure.com/test',
        'azure_whisper_key': 'key',
      });

      final service = CloudTranscriptionService(
        storage: fakeStorage,
        httpClientFactory: () => fakeClient,
      );

      // 2 seconds of silence
      final samples = List<double>.filled(32000, 0.0);
      await service.transcribe(samples);

      final body = fakeClient.capturedRequest!.capturedBody;
      // WAV body should contain RIFF header
      final bodyStr = String.fromCharCodes(body);
      expect(bodyStr, contains('RIFF'));
      expect(bodyStr, contains('WAVE'));
    });
  });
}
