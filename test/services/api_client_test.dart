// ApiClient: URL construction, the auth header, the timeout budget and the
// `{success, statusCode, message}` contract.
//
// Every case runs inside `http.runWithClient`, which installs a [MockClient] for
// the zone. That is the only seam required: [ApiClient] reaches the network through
// the top-level `http.get` / `http.post` helpers, each of which constructs a
// `Client()` per request, and `Client()` honours the zone override. No production
// code is shaped for testability here and no dependency is added —
// `package:http/testing.dart` ships inside `http` itself.
//
// What is under test is the promise the class header makes: `_send` never throws,
// so a caller's entire error path is `if (data['success'] != true)`. A raw
// [http.ClientException] must therefore be translated into a sentence, a proxy's
// HTML error page must still decode to the same shape, and a response without a
// `success` flag must have one derived rather than be read as a failure.
//
// The cold/warm budget is process-global static state, so the timeout cases drive
// it deliberately — a connection error resets it to cold, any response at all warms
// it — rather than depending on the order the cases happen to run in. Both are
// advanced on the fake clock inside [testWidgets]; a real 45 second wait would make
// this file unrunnable.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sportlynk/services/api_service.dart';

/// The default `ApiConstants.baseUrl` on the Dart VM: `kIsWeb` is false in a test
/// and no `API_BASE_URL` define is passed, so the emulator address is what every
/// URL assertion below is built from.
const base = 'http://10.0.2.2:3000/api';

/// Runs [body] against a single canned answer and records what was sent.
Future<Map<String, dynamic>> call(
  Future<Map<String, dynamic>> Function() body,
  List<http.Request> sent, {
  String responseBody = '{"success":true}',
  int status = 200,
  Object? throws,
}) =>
    http.runWithClient(
      body,
      () => MockClient((req) async {
        sent.add(req);
        if (throws != null) throw throws;
        return http.Response(responseBody, status);
      }),
    );

/// The message [ApiClient] produces for a transport failure carrying [raw].
Future<String> connectionMessage(String raw) async {
  final data = await call(
    () => ApiClient().get('/x'),
    [],
    throws: http.ClientException(raw),
  );
  return '${data['message']}';
}

/// The message [ApiClient] produces for an HTTP [status] with no JSON body.
Future<String> statusMessage(int status) async {
  final data = await call(() => ApiClient().get('/x'), [], responseBody: '', status: status);
  return '${data['message']}';
}

void main() {
  tearDown(() => ApiClient.authToken = null);

  group('ApiClient identity', () {
    test('is a singleton, so authToken set at login is seen everywhere', () {
      expect(ApiClient(), same(ApiClient()));
    });

    test('ApiService is the old name for the same class', () {
      expect(ApiService(), same(ApiClient()));
      expect(ApiService, ApiClient);
    });
  });

  group('URL construction', () {
    test('the endpoint is appended to the one base URL', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().get('/venues'), sent);
      expect(sent.single.url.toString(), '$base/venues');
    });

    test('query parameters are encoded, not concatenated', () async {
      final sent = <http.Request>[];
      await call(
        () => ApiClient().get('/venues', queryParams: {'city': 'Lahore', 'q': 'a b&c'}),
        sent,
      );
      expect(sent.single.url.queryParameters, {'city': 'Lahore', 'q': 'a b&c'});
      expect(sent.single.url.query, 'city=Lahore&q=a+b%26c');
    });

    test('an empty parameter map leaves the URL untouched', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().get('/venues', queryParams: const {}), sent);
      expect(sent.single.url.hasQuery, isFalse);
    });

    // Uri.replace overwrites the whole query component, so an endpoint string must
    // not carry parameters of its own once queryParams is used. Every ApiConstants
    // helper builds path segments only, which is why this holds in practice.
    test('a query already on the endpoint is replaced, not merged', () async {
      final sent = <http.Request>[];
      await call(
        () => ApiClient().get('/venues?city=Lahore', queryParams: {'sport': 'futsal'}),
        sent,
      );
      expect(sent.single.url.queryParameters, {'sport': 'futsal'});
    });
  });

  group('headers', () {
    test('JSON is declared on the way out and expected back', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().get('/x'), sent);
      expect(sent.single.headers['Content-Type'], 'application/json');
      expect(sent.single.headers['Accept'], 'application/json');
    });

    test('no token anywhere means no Authorization header', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().get('/x'), sent);
      expect(sent.single.headers.containsKey('Authorization'), isFalse);
    });

    test('the static token is attached once set at login', () async {
      final sent = <http.Request>[];
      ApiClient.authToken = 'JWT-STATIC';
      await call(() => ApiClient().get('/x'), sent);
      expect(sent.single.headers['Authorization'], 'Bearer JWT-STATIC');
    });

    test('an explicit token argument wins over the static one', () async {
      final sent = <http.Request>[];
      ApiClient.authToken = 'JWT-STATIC';
      await call(() => ApiClient().get('/x', token: 'JWT-ARG'), sent);
      expect(sent.single.headers['Authorization'], 'Bearer JWT-ARG');
    });

    test('an empty token argument falls back to the static one', () async {
      final sent = <http.Request>[];
      ApiClient.authToken = 'JWT-STATIC';
      await call(() => ApiClient().get('/x', token: ''), sent);
      expect(sent.single.headers['Authorization'], 'Bearer JWT-STATIC');
    });

    test('an empty static token is treated as absent', () async {
      final sent = <http.Request>[];
      ApiClient.authToken = '';
      await call(() => ApiClient().get('/x'), sent);
      expect(sent.single.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('verbs', () {
    test('GET sends no body', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().get('/x'), sent);
      expect(sent.single.method, 'GET');
      expect(sent.single.body, isEmpty);
    });

    test('POST sends the map as JSON', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().post('/x', {'name': 'Alpha', 'teams': 8}), sent);
      expect(sent.single.method, 'POST');
      expect(sent.single.body, '{"name":"Alpha","teams":8}');
    });

    test('PUT sends the map as JSON', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().put('/x', {'bio': 'Updated'}), sent);
      expect(sent.single.method, 'PUT');
      expect(sent.single.body, '{"bio":"Updated"}');
    });

    test('PATCH sends the map as JSON', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().patch('/x', {'action': 'hide'}), sent);
      expect(sent.single.method, 'PATCH');
      expect(sent.single.body, '{"action":"hide"}');
    });

    test('DELETE carries a body when one is given', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().delete('/x', body: {'reason': 'withdrawn'}), sent);
      expect(sent.single.method, 'DELETE');
      expect(sent.single.body, '{"reason":"withdrawn"}');
    });

    test('DELETE without a body sends none', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().delete('/x'), sent);
      expect(sent.single.method, 'DELETE');
      expect(sent.single.body, isEmpty);
    });

    test('an empty POST body is still valid JSON, not an empty string', () async {
      final sent = <http.Request>[];
      await call(() => ApiClient().post('/x', const {}), sent);
      expect(sent.single.body, '{}');
    });

    test('the token travels on every verb, not only GET', () async {
      final sent = <http.Request>[];
      ApiClient.authToken = 'JWT';
      await call(() async {
        await ApiClient().post('/a', const {});
        await ApiClient().put('/b', const {});
        await ApiClient().patch('/c', const {});
        await ApiClient().delete('/d');
        return ApiClient().get('/e');
      }, sent);
      expect(sent.length, 5);
      expect(
        sent.map((r) => r.headers['Authorization']),
        everyElement('Bearer JWT'),
      );
    });
  });

  group('the {success, statusCode, message} contract', () {
    test("the API's own envelope passes through with its data intact", () async {
      final data = await call(
        () => ApiClient().get('/venues'),
        [],
        responseBody: '{"success":true,"venues":[{"id":"v1"}]}',
      );
      expect(data['success'], isTrue);
      expect((data['venues'] as List).single, {'id': 'v1'});
      expect(data['statusCode'], 200);
    });

    test('a status code the server sent itself is not overwritten', () async {
      final data = await call(
        () => ApiClient().get('/x'),
        [],
        responseBody: '{"success":false,"statusCode":409,"message":"Slot already booked"}',
        status: 400,
      );
      expect(data['statusCode'], 409);
      expect(data['message'], 'Slot already booked');
    });

    test('a 2xx without a success flag is read as a success', () async {
      final data = await call(() => ApiClient().get('/x'), [], responseBody: '{"count":3}');
      expect(data['success'], isTrue);
      expect(data['count'], 3);
    });

    test('a 4xx without a success flag is read as a failure', () async {
      final data = await call(
        () => ApiClient().get('/x'),
        [],
        responseBody: '{"detail":"nope"}',
        status: 422,
      );
      expect(data['success'], isFalse);
      expect(data['statusCode'], 422);
    });

    test('a failure without a message is given a readable one', () async {
      final data = await call(
        () => ApiClient().get('/x'),
        [],
        responseBody: '{"success":false}',
        status: 403,
      );
      expect(data['message'], 'You do not have permission to do that.');
    });

    test("a failure keeps the server's own message", () async {
      final data = await call(
        () => ApiClient().get('/x'),
        [],
        responseBody: '{"success":false,"message":"Deadline has passed"}',
        status: 400,
      );
      expect(data['message'], 'Deadline has passed');
    });

    test('a successful response is not given a message it did not send', () async {
      final data = await call(() => ApiClient().get('/x'), [], responseBody: '{"success":true}');
      expect(data.containsKey('message'), isFalse);
    });

    test("a proxy's HTML error page still decodes to the contract", () async {
      final data = await call(
        () => ApiClient().get('/x'),
        [],
        responseBody: '<html><body>502 Bad Gateway</body></html>',
        status: 502,
      );
      expect(data['success'], isFalse);
      expect(data['statusCode'], 502);
      expect(data['message'], 'The server is waking up. Please try again in a few seconds.');
    });

    test('an empty body on a 204 is reported as a failure, not silent success', () async {
      // Nothing in this API answers 204: every route returns the envelope, so an
      // empty body means the response did not come from the application.
      final data = await call(() => ApiClient().get('/x'), [], responseBody: '', status: 204);
      expect(data['success'], isFalse);
      expect(data['message'], 'Unexpected response from the server.');
    });

    test('a JSON array is not the envelope and falls back to the status', () async {
      final data = await call(() => ApiClient().get('/x'), [], responseBody: '[1,2,3]');
      expect(data['success'], isFalse);
      expect(data['statusCode'], 200);
      expect(data['message'], 'Unexpected response from the server.');
    });

    test('a JSON string body is not the envelope either', () async {
      final data = await call(() => ApiClient().get('/x'), [], responseBody: '"ok"');
      expect(data['success'], isFalse);
    });
  });

  group('status messages', () {
    test('401 names the session rather than the status code', () async {
      expect(await statusMessage(401), 'Your session has expired. Please log in again.');
    });

    test('403 names permission', () async {
      expect(await statusMessage(403), 'You do not have permission to do that.');
    });

    test('404 names the server', () async {
      expect(await statusMessage(404), 'That was not found on the server.');
    });

    test('429 asks for a pause', () async {
      expect(await statusMessage(429), 'Too many requests. Please wait a moment and try again.');
    });

    test('502, 503 and 504 all read as a cold start', () async {
      const waking = 'The server is waking up. Please try again in a few seconds.';
      expect(await statusMessage(502), waking);
      expect(await statusMessage(503), waking);
      expect(await statusMessage(504), waking);
    });

    test('any other 5xx blames the server, not the caller', () async {
      expect(await statusMessage(500), 'Something went wrong on the server.');
      expect(await statusMessage(599), 'Something went wrong on the server.');
    });

    test('any other 4xx stays vague rather than guessing', () async {
      expect(await statusMessage(418), 'That request could not be completed.');
    });

    test('a redirect reaching the client at all is unexpected', () async {
      expect(await statusMessage(302), 'Unexpected response from the server.');
    });
  });

  group('connection messages', () {
    test('a DNS failure is reported as no internet', () async {
      const offline = 'No internet connection. Check your mobile data or Wi-Fi.';
      expect(
        await connectionMessage('Failed host lookup: sportlynk.onrender.com'),
        offline,
      );
      expect(await connectionMessage('nodename nor servname provided'), offline);
      expect(await connectionMessage('No address associated with hostname'), offline);
    });

    test('a refused or reset connection points at the server being down', () async {
      const down = 'Could not reach the server. Make sure it is running.';
      expect(await connectionMessage('Connection refused'), down);
      expect(await connectionMessage('Connection reset by peer'), down);
    });

    test('a TLS or cleartext block is named as such', () async {
      const tls = 'Could not establish a secure connection to the server.';
      expect(await connectionMessage('Cleartext HTTP traffic to 10.0.2.2 not permitted'), tls);
      expect(await connectionMessage('HandshakeException: connection terminated'), tls);
      expect(await connectionMessage('CERTIFICATE_VERIFY_FAILED'), tls);
    });

    test('an unreachable network is separated from a dead server', () async {
      const unreachable = 'Network unavailable. Check your connection and try again.';
      expect(await connectionMessage('Network is unreachable'), unreachable);
      expect(await connectionMessage('Software caused connection abort'), unreachable);
    });

    test('an unrecognised transport failure still gets a sentence', () async {
      expect(
        await connectionMessage('SocketException: something entirely new'),
        'Could not reach the server. Check your connection and try again.',
      );
    });

    test('matching is case-insensitive, since the wording varies by platform', () async {
      expect(
        await connectionMessage('FAILED HOST LOOKUP'),
        'No internet connection. Check your mobile data or Wi-Fi.',
      );
    });
  });

  group('never throws', () {
    test('an error that is not a ClientException is still translated', () async {
      final data = await call(
        () => ApiClient().get('/x'),
        [],
        throws: StateError('Connection refused by the fake transport'),
      );
      expect(data['success'], isFalse);
      expect(data['statusCode'], 0);
      expect(data['message'], 'Could not reach the server. Make sure it is running.');
    });

    test('a body that is not encodable is caught rather than thrown at the caller', () async {
      // jsonEncode fails before the request is built, so this exercises the outer
      // catch: the caller must still receive the envelope.
      final data = await call(() => ApiClient().post('/x', {'when': DateTime(2026, 3, 14)}), []);
      expect(data['success'], isFalse);
      expect(data['statusCode'], 0);
      expect(data['message'], isA<String>());
    });
  });

  group('the cold and warm budgets', () {
    testWidgets('the first request of a session waits out a cold start', (tester) async {
      // A transport failure is what resets the budget to cold, so the state this
      // case needs is established rather than assumed.
      await call(() => ApiClient().get('/warm-down'), [], throws: http.ClientException('reset'));
      expect(ApiClient.isCold, isTrue);

      final never = Completer<http.Response>();
      Future<Map<String, dynamic>>? pending;
      http.runWithClient(
        () => pending = ApiClient().get('/slow'),
        () => MockClient((_) => never.future),
      );

      await tester.pump(const Duration(seconds: 30));
      expect(pending, isNotNull);

      await tester.pump(const Duration(seconds: 16));
      final data = await pending!;
      expect(data['success'], isFalse);
      expect(data['statusCode'], 0);
      expect(data['message'], 'The server is waking up. Please try again in a few seconds.');
    });

    testWidgets('a warmed client fails fast and says so differently', (tester) async {
      await call(() => ApiClient().get('/warm-up'), []);
      expect(ApiClient.isCold, isFalse);

      final never = Completer<http.Response>();
      Future<Map<String, dynamic>>? pending;
      http.runWithClient(
        () => pending = ApiClient().get('/slow'),
        () => MockClient((_) => never.future),
      );

      await tester.pump(const Duration(seconds: 11));
      final data = await pending!;
      expect(
        data['message'],
        'The server took too long to respond. Check your connection and try again.',
      );
    });

    testWidgets('a timeout does not put the client back into cold start', (tester) async {
      // A slow answer is not evidence the container slept, so the short budget is
      // kept: the alternative is a 45 second spinner on every retry over a bad link.
      await call(() => ApiClient().get('/warm-up'), []);

      final never = Completer<http.Response>();
      Future<Map<String, dynamic>>? pending;
      http.runWithClient(
        () => pending = ApiClient().get('/slow'),
        () => MockClient((_) => never.future),
      );
      await tester.pump(const Duration(seconds: 11));
      await pending!;

      expect(ApiClient.isCold, isFalse);
    });

    test('any answer at all counts as awake, including a 500', () async {
      await call(() => ApiClient().get('/x'), [], throws: http.ClientException('reset'));
      expect(ApiClient.isCold, isTrue);
      await call(() => ApiClient().get('/x'), [], responseBody: '', status: 500);
      expect(ApiClient.isCold, isFalse);
    });

    test('a transport failure hands the long budget back', () async {
      await call(() => ApiClient().get('/x'), []);
      expect(ApiClient.isCold, isFalse);
      await call(() => ApiClient().get('/x'), [], throws: http.ClientException('refused'));
      expect(ApiClient.isCold, isTrue);
    });
  });
}
