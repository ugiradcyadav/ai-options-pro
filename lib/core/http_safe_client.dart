import 'package:http/http.dart' as http;

/// Blocks automatic HTTP redirects on authenticated broker calls so
/// Authorization headers and API keys are never forwarded across origins.
class SafeBrokerHttp {
  static Future<http.Response> get(
    Uri uri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    return _send('GET', uri, headers: headers, timeout: timeout);
  }

  static Future<http.Response> post(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    return _send('POST', uri, headers: headers, body: body, timeout: timeout);
  }

  static Future<http.Response> _send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    String? body,
    required Duration timeout,
  }) async {
    final client = http.Client();
    try {
      final req = http.Request(method, uri);
      req.followRedirects = false;
      req.maxRedirects = 0;
      if (headers != null) req.headers.addAll(headers);
      if (body != null) req.body = body;
      final streamed = await client.send(req).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } finally {
      client.close();
    }
  }
}
