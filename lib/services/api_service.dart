import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants/api_constants.dart';

/// The single place every HTTP call should go through.
///
/// Four things live here so they don't have to live in 22 screens:
///
/// 1. **One base URL.** `ApiConstants.baseUrl` is read here and nowhere else in
///    new code, so switching between emulator / LAN / Render is one
///    `--dart-define` (see README "Run modes").
/// 2. **A timeout.** Before this, a request to an unreachable host hung until
///    the OS gave up — minutes of a frozen spinner. Note [_coldTimeout]: the
///    first call of a session gets much longer, because Render's free tier
///    sleeps and takes ~30s to wake. A flat 10s would fail *every* demo's first
///    request.
/// 3. **A JWT, attached once.** Pass `token:` as before, or set
///    [ApiClient.authToken] at login and forget about it.
/// 4. **Errors a human can read.** Every failure path returns the same
///    `{success: false, message: <sentence>}` shape the backend uses, so callers
///    can render `message` directly. Raw `ClientException: Failed host lookup`
///    text never reaches a user.
///
/// Migration is deliberately opportunistic — screens move over as they are
/// touched, not in one risky sweep. Direct `http.get` calls elsewhere still work.
class ApiClient {
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;
  ApiClient._internal();

  /// Normal per-request budget once the server is known to be awake.
  static const Duration _warmTimeout = Duration(seconds: 10);

  /// Budget until the first successful response of this app session.
  ///
  /// Render's free plan spins the container down after ~15 minutes idle and
  /// cold-starts in roughly 30 seconds. 45s covers that with margin; after one
  /// success the bound drops to [_warmTimeout] so a genuinely dead network still fails
  /// fast. Reset to cold on a connection error, since sleeping is the likeliest
  /// cause and the next attempt deserves the long budget again.
  static const Duration _coldTimeout = Duration(seconds: 45);

  static bool _warmed = false;

  /// Set once after login so screens don't have to thread a token through.
  /// A `token:` argument always wins over this.
  static String? authToken;

  /// True while the next request will still use the long cold-start budget —
  /// useful for showing "waking the server up, this can take 30 seconds".
  static bool get isCold => !_warmed;

  static Duration get _timeout => _warmed ? _warmTimeout : _coldTimeout;

  Map<String, String> _headers({String? token}) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    final t = (token != null && token.isNotEmpty) ? token : authToken;
    if (t != null && t.isNotEmpty) {
      headers['Authorization'] = 'Bearer $t';
    }
    return headers;
  }

  Uri _uri(String endpoint, [Map<String, String>? queryParams]) {
    var uri = Uri.parse('${ApiConstants.baseUrl}$endpoint');
    if (queryParams != null && queryParams.isNotEmpty) {
      uri = uri.replace(queryParameters: queryParams);
    }
    return uri;
  }

  Future<Map<String, dynamic>> get(
    String endpoint, {
    String? token,
    Map<String, String>? queryParams,
  }) {
    return _send(
      'GET',
      endpoint,
      (uri, headers) => http.get(uri, headers: headers),
      token: token,
      queryParams: queryParams,
    );
  }

  Future<Map<String, dynamic>> post(
    String endpoint,
    Map<String, dynamic> body, {
    String? token,
  }) {
    return _send(
      'POST',
      endpoint,
      (uri, headers) => http.post(uri, headers: headers, body: jsonEncode(body)),
      token: token,
    );
  }

  Future<Map<String, dynamic>> put(
    String endpoint,
    Map<String, dynamic> body, {
    String? token,
  }) {
    return _send(
      'PUT',
      endpoint,
      (uri, headers) => http.put(uri, headers: headers, body: jsonEncode(body)),
      token: token,
    );
  }

  Future<Map<String, dynamic>> patch(
    String endpoint,
    Map<String, dynamic> body, {
    String? token,
  }) {
    return _send(
      'PATCH',
      endpoint,
      (uri, headers) => http.patch(uri, headers: headers, body: jsonEncode(body)),
      token: token,
    );
  }

  /// DELETE, with an optional body — slot-lock release and withdrawal cancel
  /// both need this verb, which the old ApiService simply did not have.
  Future<Map<String, dynamic>> delete(
    String endpoint, {
    Map<String, dynamic>? body,
    String? token,
  }) {
    return _send(
      'DELETE',
      endpoint,
      (uri, headers) => http.delete(
        uri,
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
      token: token,
    );
  }

  /// The one code path all five verbs share: send, time out, decode, translate.
  ///
  /// Never throws. Callers always get a decoded map with a `success` flag, so a
  /// screen's error handling is a single `if (data['success'] != true)`.
  Future<Map<String, dynamic>> _send(
    String method,
    String endpoint,
    Future<http.Response> Function(Uri uri, Map<String, String> headers) call, {
    String? token,
    Map<String, String>? queryParams,
  }) async {
    final uri = _uri(endpoint, queryParams);
    try {
      final response =
          await call(uri, _headers(token: token)).timeout(_timeout);

      // Any answer at all — even a 500 — proves the container is awake.
      _warmed = true;
      return _decode(response);
    } on TimeoutException {
      return {
        'success': false,
        'statusCode': 0,
        'message': _warmed
            ? 'The server took too long to respond. Check your connection and try again.'
            : 'The server is waking up. Please try again in a few seconds.',
      };
    } on http.ClientException catch (e) {
      // Failed host lookup, connection refused, connection reset — all surface
      // as ClientException on both mobile and web.
      _warmed = false; // next attempt gets the long cold-start budget back
      return {
        'success': false,
        'statusCode': 0,
        'message': _connectionMessage(e.message),
      };
    } catch (e) {
      _warmed = false;
      return {
        'success': false,
        'statusCode': 0,
        'message': _connectionMessage(e.toString()),
      };
    }
  }

  /// Turn an HTTP response into the `{success, ...}` contract.
  ///
  /// The backend already answers in that shape for every route (including its
  /// 404 and its global error handler), so normally this just decodes. The
  /// fallbacks below are for the cases that are *not* this API's own JSON: a proxy's
  /// HTML error page, a Render cold-start 502, or a rate-limit response.
  Map<String, dynamic> _decode(http.Response response) {
    final status = response.statusCode;

    Map<String, dynamic>? decoded;
    if (response.body.isNotEmpty) {
      try {
        final parsed = jsonDecode(response.body);
        if (parsed is Map<String, dynamic>) decoded = parsed;
      } catch (_) {
        decoded = null; // not JSON — handled below
      }
    }

    if (decoded != null) {
      decoded.putIfAbsent('statusCode', () => status);
      // Trust an explicit flag from the app's own API; otherwise derive one so a
      // hand-written response without `success` still behaves sanely.
      decoded.putIfAbsent('success', () => status >= 200 && status < 300);
      if (decoded['success'] != true && decoded['message'] == null) {
        decoded['message'] = _statusMessage(status);
      }
      return decoded;
    }

    return {
      'success': false,
      'statusCode': status,
      'message': _statusMessage(status),
    };
  }

  String _statusMessage(int status) {
    if (status == 401) return 'Your session has expired. Please log in again.';
    if (status == 403) return 'You do not have permission to do that.';
    if (status == 404) return 'That was not found on the server.';
    if (status == 429) {
      return 'Too many requests. Please wait a moment and try again.';
    }
    if (status == 502 || status == 503 || status == 504) {
      return 'The server is waking up. Please try again in a few seconds.';
    }
    if (status >= 500) return 'Something went wrong on the server.';
    if (status >= 400) return 'That request could not be completed.';
    return 'Unexpected response from the server.';
  }

  String _connectionMessage(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('failed host lookup') ||
        m.contains('nodename nor servname') ||
        m.contains('no address associated')) {
      return 'No internet connection. Check your mobile data or Wi-Fi.';
    }
    if (m.contains('connection refused') || m.contains('connection reset')) {
      return 'Could not reach the server. Make sure it is running.';
    }
    if (m.contains('cleartext') || m.contains('handshake') || m.contains('certificate')) {
      return 'Could not establish a secure connection to the server.';
    }
    if (m.contains('network is unreachable') || m.contains('software caused')) {
      return 'Network unavailable. Check your connection and try again.';
    }
    return 'Could not reach the server. Check your connection and try again.';
  }
}

/// The original name, kept so `AuthService` and anything else already importing
/// this file keeps compiling. New code should say `ApiClient`.
typedef ApiService = ApiClient;
