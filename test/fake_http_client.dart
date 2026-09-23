import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Scriptable in-memory [http.Client] for backend tests: records every
/// request (URL, headers, body) and replays pre-queued responses.
class FakeHttpClient implements http.Client {
  final requests = <http.Request>[];

  final _queued =
      <Future<http.StreamedResponse> Function(http.BaseRequest)>[];

  /// Queue a JSON response.
  void enqueueJson(int status, Object body) {
    _queued.add((_) async {
      final r = jsonEncode(body);
      return http.StreamedResponse(
          Stream.value(utf8.encode(r)), status,
          headers: {'content-type': 'application/json'});
    });
  }

  /// Queue an SSE (text/event-stream) response whose lines stream out.
  void enqueueSse(int status, List<String> dataLines) {
    final payload = dataLines.map((l) => '$l\n\n').join();
    _queued.add((_) async => http.StreamedResponse(
          Stream.value(utf8.encode(payload)),
          status,
          headers: {'content-type': 'text/event-stream'},
        ));
  }

  Never _throwIfEmpty(http.BaseRequest request) {
    throw StateError('No queued response for ${request.method} ${request.url}');
  }

  Future<http.StreamedResponse> _next(http.BaseRequest request) async {
    if (_queued.isEmpty) _throwIfEmpty(request);
    return _queued.removeAt(0)(request);
  }

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    final req = http.Request('GET', url)..headers.addAll(headers ?? {});
    requests.add(req);
    final streamed = await _next(req);
    return http.Response.fromStream(streamed);
  }

  @override
  Future<http.Response> post(Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    final req = http.Request('POST', url)..headers.addAll(headers ?? {});
    requests.add(req);
    if (body is String) {
      req.body = body;
    } else if (body is List<int>) {
      req.bodyBytes = body;
    }
    final streamed = await _next(req);
    return http.Response.fromStream(streamed);
  }

  @override
  Future<http.Response> patch(Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    final req = http.Request('PATCH', url)..headers.addAll(headers ?? {});
    requests.add(req);
    final streamed = await _next(req);
    return http.Response.fromStream(streamed);
  }

  @override
  Future<http.Response> put(Uri url,
      {Map<String, String>? headers, Object? body, Encoding? encoding}) async {
    final req = http.Request('PUT', url)..headers.addAll(headers ?? {});
    requests.add(req);
    final streamed = await _next(req);
    return http.Response.fromStream(streamed);
  }

  @override
  Future<http.Response> delete(Uri url,
      {Object? body, Encoding? encoding, Map<String, String>? headers}) async {
    final req = http.Request('DELETE', url)..headers.addAll(headers ?? {});
    requests.add(req);
    final streamed = await _next(req);
    return http.Response.fromStream(streamed);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request is http.Request
        ? request
        : http.Request(request.method, request.url));
    return _next(request);
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
