// The HTTP seam every service test in this directory runs through.
//
// The services reach the network by way of [ApiClient], which calls the top-level
// `http.get` / `http.post` helpers. Each of those constructs a `Client()` per
// request, and `Client()` honours the override installed by `http.runWithClient`,
// so wrapping a test body in [FakeApi.run] intercepts the whole call chain without
// altering a line of production code and without adding a dependency —
// `package:http/testing.dart` is part of `http` itself.
//
// Answers are a queue rather than a route table. A service method's contract is
// "given this reply, produce this result", and the order of the calls it makes is
// itself part of that contract; a table keyed on path would hide a service that
// fetched the same endpoint twice or fetched them in the wrong order. Once the
// queue is drained the last answer repeats, so a test that only cares about the
// request needs to queue exactly one.
//
// One answer can be queued as bytes with headers rather than as a string, because
// `ReportService` bypasses [ApiClient] for the CSV download: that route answers
// `text/csv` with a `Content-Disposition` filename and a UTF-8 BOM, none of which
// survives a JSON envelope. Those are the only tests that need either, so the string
// path is left exactly as it was.
//
// [ApiClient] holds the bearer token in process-global static state, so
// [resetApiClient] clears it between cases: without that, a file that logs in leaks
// an Authorization header into whichever file the runner executes next. The other
// static — the cold-start flag — is left alone deliberately, because no test here
// lets a request time out and its only effect is which budget the timeout uses.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sportlynk/constants/api_constants.dart';
import 'package:sportlynk/services/api_service.dart';

/// One queued answer: a response, a byte-for-byte response, or a transport failure.
class _Answer {
  final int status;
  final String body;

  /// Set only when the test needs the exact bytes preserved, as the CSV's BOM does.
  final List<int>? bytes;

  final Map<String, String> headers;
  final Object? error;

  const _Answer({
    this.status = 200,
    this.body = '',
    this.bytes,
    this.headers = const {},
    this.error,
  });
}

/// A recording fake for the whole API surface.
class FakeApi {
  /// Every request the code under test actually sent, in order.
  final List<http.Request> sent = <http.Request>[];

  final List<_Answer> _answers = <_Answer>[];

  /// Queues a raw body with an explicit status — for the responses that are not
  /// this API's envelope at all (an HTML error page, a CSV, an empty 500).
  void raw(String body, {int status = 200, Map<String, String>? headers}) =>
      _answers.add(_Answer(status: status, body: body, headers: headers ?? const {}));

  /// Queues a response whose bytes reach the caller untouched, for the one route
  /// whose leading BOM is part of the contract.
  void rawBytes(List<int> bytes, {int status = 200, Map<String, String>? headers}) =>
      _answers.add(_Answer(status: status, bytes: bytes, headers: headers ?? const {}));

  /// Queues a JSON body verbatim, which is how a malformed or unexpected shape is
  /// set up without hand-writing the encoder.
  void json(Object? body, {int status = 200}) =>
      raw(jsonEncode(body), status: status);

  /// Queues the success envelope the backend sends: `{success: true, data: …}`.
  void ok(Object? data, {int status = 200, Map<String, dynamic>? extra}) => json({
        'success': true,
        'data': data,
        ...?extra,
      }, status: status);

  /// Queues the failure envelope, carrying the sentence a screen is expected to
  /// show the user.
  void fail(String message, {int status = 400}) =>
      json({'success': false, 'message': message}, status: status);

  /// Queues a transport failure — no response at all, which is what a dead server
  /// or a missing `adb reverse` produces.
  void offline([String raw = 'Connection refused']) =>
      _answers.add(_Answer(error: http.ClientException(raw)));

  /// Queues a timeout, for the budgets a service enforces itself.
  void hang() => _answers.add(const _Answer(error: _NeverAnswers()));

  /// Runs [body] with every HTTP call answered from the queue.
  Future<T> run<T>(Future<T> Function() body) => http.runWithClient(body, () {
        return MockClient((request) async {
          sent.add(request);
          if (_answers.isEmpty) {
            fail('the test queued no answer for ${request.method} ${request.url}');
          }
          final answer = _answers.length == 1 ? _answers.first : _answers.removeAt(0);
          if (answer.error is _NeverAnswers) {
            // A never-completing future rather than a long delay: a pending timer would
            // outlive a widget test and be reported as a leak instead of a timeout.
            await Completer<void>().future;
          }
          if (answer.error != null) throw answer.error!;
          final bytes = answer.bytes;
          return bytes == null
              ? http.Response(answer.body, answer.status, headers: answer.headers)
              : http.Response.bytes(bytes, answer.status, headers: answer.headers);
        });
      });

  /// The one request that was sent, when a test asserts there was only one.
  http.Request get only => sent.single;

  /// The endpoint of request [i] with the base URL stripped, so an assertion reads
  /// the same string `ApiConstants` declares.
  String endpoint([int i = 0]) {
    final url = sent[i].url;
    final path = url.path.replaceFirst(Uri.parse(ApiConstants.baseUrl).path, '');
    return url.hasQuery ? '$path?${url.query}' : path;
  }

  /// The decoded JSON body of request [i].
  Map<String, dynamic> body([int i = 0]) =>
      Map<String, dynamic>.from(jsonDecode(sent[i].body) as Map);

  /// The query parameters of request [i].
  Map<String, String> query([int i = 0]) => sent[i].url.queryParameters;

  /// The bearer token on request [i], or null when no header was attached.
  String? token([int i = 0]) =>
      sent[i].headers['Authorization']?.replaceFirst('Bearer ', '');

  /// One request header of request [i], by name.
  String? header(String name, [int i = 0]) => sent[i].headers[name];

  /// The HTTP method of request [i].
  String method([int i = 0]) => sent[i].method;
}

/// The marker for a queued answer that never arrives, so a service's own timeout is
/// what ends the call.
class _NeverAnswers implements Exception {
  const _NeverAnswers();
}

/// Clears the static bearer token, so no service test inherits one from another
/// file. Called from `tearDown` in every test file in this directory.
void resetApiClient() {
  ApiClient.authToken = null;
}
