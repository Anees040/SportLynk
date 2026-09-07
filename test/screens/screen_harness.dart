// The harness every screen test in this directory pumps through.
//
// A screen is a different test subject from a widget. A widget in `lib/widgets/` is
// handed its data and asked to draw it; a screen fetches its own, which means the
// interesting assertions are about the four states the project mandates — loading,
// empty, error with a retry, loaded — and those states are reachable only by
// controlling what the network returns.
//
// There is no mocking package in `pubspec.yaml` and this file does not add one. It
// does not need to: both transports in this app bottom out in `package:http`'s
// default client, which resolves `HttpOverrides.global` on every request. Nineteen
// screens call top-level `http.get` directly and the rest go through `ApiClient`, and
// a single override intercepts both. [FakeApi] is that override.
//
// Without it, `flutter_test` answers every request with a 400 and an empty body. That
// is not a neutral default — it is one of the four states, silently — so a screen test
// written without an override is only ever asserting the error path while appearing to
// assert the loaded one. Every test here installs a [FakeApi], including the ones that
// want a failure, so the failure is the one the test chose.
//
// What the fake matches on is the path, not the full url. Query strings carry filters,
// pagination and cache-busting values that differ per screen and per rebuild, and a
// fixture keyed on the whole url would silently stop matching the first time a screen
// added a parameter — falling through to a 404 that reads exactly like an empty list.
// [FakeApi.on] therefore keys on the path alone and exposes [requests] so a test can
// assert on the query it was given.
//
// A screen that calls an endpoint the fixture has no entry for gets a 404 whose body
// names the path. That is deliberate: an unstubbed endpoint should be a legible
// failure in the test output rather than an empty state that looks plausible.
//
// Authentication is the second thing every screen needs. All of them read
// `Provider.of<AuthProvider>(context, listen: false).token!` — a bang, so a screen
// pumped without a session throws a null-check error before it ever paints.
// [FakeAuth] is a subclass rather than a mock: `AuthProvider`'s getters are ordinary
// virtual members, so overriding four of them supplies a signed-in identity without
// touching the real login path or `shared_preferences`.
//
// Nothing here settles. Screens show `CircularProgressIndicator` and `CustomLoader`
// while loading, both of which animate forever, so `pumpAndSettle` would time out
// rather than report anything useful. Tests advance with explicit `pump(Duration)`
// calls, and [settleData] is the one-line form of "let the in-flight fetch complete
// and rebuild".

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:sportlynk/constants/app_theme.dart';
import 'package:sportlynk/models/user.dart';
import 'package:sportlynk/providers/auth_provider.dart';
import 'package:sportlynk/services/api_service.dart';

/// One request a screen made, as recorded by [FakeApi].
class RecordedRequest {
  final String method;
  final Uri uri;
  final String? body;

  const RecordedRequest({required this.method, required this.uri, this.body});

  /// The path with no query string, which is what fixtures are keyed on.
  String get path => uri.path;

  /// A query parameter the screen sent, or null when it sent none.
  String? param(String name) => uri.queryParameters[name];

  @override
  String toString() => '$method ${uri.path}'
      '${uri.query.isEmpty ? '' : '?${uri.query}'}';
}

/// What [FakeApi] should answer with for one path.
class FakeResponse {
  final int status;
  final String body;
  final Duration delay;

  const FakeResponse(this.status, this.body, {this.delay = Duration.zero});

  /// A 200 carrying the project's envelope, which every service unwraps as
  /// `json['data']`.
  factory FakeResponse.ok(Object? data, {Duration delay = Duration.zero}) =>
      FakeResponse(
        200,
        jsonEncode({'success': true, 'data': data}),
        delay: delay,
      );

  /// A failure carrying a message the screen is expected to show. The envelope
  /// shape matters: `ApiClient` reads `message` off the body and a screen that
  /// prints the raw exception instead is a bug this makes visible.
  factory FakeResponse.fail(
    String message, {
    int status = 500,
    Duration delay = Duration.zero,
  }) =>
      FakeResponse(
        status,
        jsonEncode({'success': false, 'message': message}),
        delay: delay,
      );

  /// A dropped connection — no status line at all, which is what a phone with no
  /// route to the API actually produces.
  static const FakeResponse offline = FakeResponse(-1, '');

  bool get isDropped => status == -1;
}

/// Intercepts every request the app makes, for the lifetime of one test.
///
/// Install with [install], which registers the tear-down that puts the previous
/// override back — one test's fixture reaching the next would make failures depend
/// on file order.
class FakeApi extends HttpOverrides {
  final Map<String, FakeResponse> _byPath = <String, FakeResponse>{};
  final List<RecordedRequest> requests = <RecordedRequest>[];

  /// Answer [path] with [response]. The path is matched without its query string;
  /// a later call for the same path replaces the earlier one, so a test can stub a
  /// failure, tap Retry, and stub a success for the second attempt.
  FakeApi on(String path, FakeResponse response) {
    _byPath[_normalise(path)] = response;
    return this;
  }

  /// Answer [path] with a 200 and the project's envelope around [data].
  FakeApi ok(String path, Object? data, {Duration delay = Duration.zero}) =>
      on(path, FakeResponse.ok(data, delay: delay));

  /// Answer [path] with a failure the screen should surface.
  FakeApi fail(
    String path,
    String message, {
    int status = 500,
    Duration delay = Duration.zero,
  }) =>
      on(path, FakeResponse.fail(message, status: status, delay: delay));

  /// Answer [path] as if the phone had no route to the API.
  FakeApi offline(String path) => on(path, FakeResponse.offline);

  /// Every request made so far whose path ends with [suffix].
  List<RecordedRequest> to(String suffix) =>
      requests.where((r) => r.path.endsWith(suffix)).toList();

  /// How many requests were made to a path ending with [suffix]. A pull-to-refresh
  /// that fetches twice, or a filter change that does not fetch at all, is only
  /// visible as a count.
  int countTo(String suffix) => to(suffix).length;

  /// Installs this fake as the process-wide override and restores the previous one
  /// on tear-down.
  void install() {
    final previous = HttpOverrides.current;
    HttpOverrides.global = this;
    addTearDown(() => HttpOverrides.global = previous);
  }

  static String _normalise(String path) {
    final withoutQuery = path.split('?').first;
    return withoutQuery.endsWith('/') && withoutQuery.length > 1
        ? withoutQuery.substring(0, withoutQuery.length - 1)
        : withoutQuery;
  }

  FakeResponse _match(Uri uri) {
    final path = _normalise(uri.path);
    final exact = _byPath[path];
    if (exact != null) return exact;
    // A suffix match keeps fixtures readable: a test stubs `/venues` rather than
    // repeating the `/api` prefix that `ApiConstants.baseUrl` contributes.
    for (final entry in _byPath.entries) {
      if (path.endsWith(entry.key)) return entry.value;
    }
    return FakeResponse(
      404,
      jsonEncode({
        'success': false,
        'message': 'no fixture for $path — add one with FakeApi.on',
      }),
    );
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient(this);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._api);

  final FakeApi _api;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeHttpClientRequest(_api, method, url);

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  void close({bool force = false}) {}

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this._api, this.method, this.uri);

  final FakeApi _api;

  @override
  final String method;

  @override
  final Uri uri;

  final List<int> _body = <int>[];

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Encoding encoding = utf8;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  @override
  int contentLength = -1;

  @override
  bool persistentConnection = true;

  @override
  bool bufferOutput = true;

  @override
  void add(List<int> data) => _body.addAll(data);

  @override
  void write(Object? obj) => _body.addAll(utf8.encode(obj?.toString() ?? ''));

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeln([Object? obj = '']) => write('$obj\n');

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _body.addAll(chunk);
    }
  }

  @override
  Future<HttpClientResponse> close() async {
    _api.requests.add(
      RecordedRequest(
        method: method,
        uri: uri,
        body: _body.isEmpty ? null : utf8.decode(_body),
      ),
    );
    final response = _api._match(uri);
    if (response.delay > Duration.zero) {
      await Future<void>.delayed(response.delay);
    }
    if (response.isDropped) {
      throw const SocketException('the phone has no route to the API');
    }
    return _FakeHttpClientResponse(response);
  }

  @override
  Future<HttpClientResponse> get done => close();

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this._response);

  final FakeResponse _response;

  @override
  int get statusCode => _response.status;

  @override
  String get reasonPhrase => _response.status == 200 ? 'OK' : 'Error';

  @override
  int get contentLength => utf8.encode(_response.body).length;

  @override
  final HttpHeaders headers = _FakeHeaders()
    ..contentType = ContentType.json;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const <RedirectInfo>[];

  @override
  bool get persistentConnection => false;

  @override
  List<Cookie> get cookies => const <Cookie>[];

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(utf8.encode(_response.body)).listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  noSuchMethod(Invocation invocation) => null;
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = <String, List<String>>{};

  /// Published into the header map as well as read from it, rather than held as a
  /// plain field. `package:http` takes the body's charset from `content-type` and
  /// falls back to latin-1 when the header is absent, which decodes every
  /// non-ASCII character in a fixture into mojibake and fails an expectation that
  /// is correct. The real API answers `application/json; charset=utf-8`.
  @override
  ContentType? get contentType {
    final raw = value(HttpHeaders.contentTypeHeader);
    return raw == null ? null : ContentType.parse(raw);
  }

  @override
  set contentType(ContentType? type) {
    if (type == null) {
      removeAll(HttpHeaders.contentTypeHeader);
    } else {
      set(HttpHeaders.contentTypeHeader, type.toString());
    }
  }

  @override
  int contentLength = -1;

  @override
  bool chunkedTransferEncoding = false;

  @override
  bool persistentConnection = true;

  @override
  DateTime? date;

  @override
  DateTime? expires;

  @override
  DateTime? ifModifiedSince;

  @override
  String? host;

  @override
  int? port;

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values.putIfAbsent(name.toLowerCase(), () => <String>[])
          .add(value.toString());

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = <String>[value.toString()];

  @override
  String? value(String name) {
    final v = _values[name.toLowerCase()];
    return v == null || v.isEmpty ? null : v.first;
  }

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  void remove(String name, Object value) =>
      _values[name.toLowerCase()]?.remove(value.toString());

  @override
  void removeAll(String name) => _values.remove(name.toLowerCase());

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _values.forEach(action);

  @override
  void noFolding(String name) {}

  @override
  void clear() => _values.clear();
}

/// A signed-in identity, without the login path or `shared_preferences`.
///
/// Every screen reads the token with a bang — `.token!` — so a screen pumped
/// without one throws a null-check error before its first paint. Only the four
/// members the screens actually read are overridden; the rest of [AuthProvider] is
/// inherited and untouched, which is what keeps this a fixture rather than a second
/// implementation of the real thing.
class FakeAuth extends AuthProvider {
  FakeAuth({
    String role = 'player',
    String id = 'u-1',
    String name = 'Bilal Ahmed',
    String? token = 'test-token',
  })  : _user = User(
          id: id,
          name: name,
          email: 'bilal@example.com',
          phone: '+923001234567',
          role: role,
        ),
        _token = token {
    // Screens that go through `ApiClient` read the token off the static rather than
    // the provider, and a token left behind by a previous test would let a screen
    // appear authenticated for the wrong reason.
    ApiClient.authToken = token;
    addTearDown(() => ApiClient.authToken = null);
  }

  final User _user;
  final String? _token;

  @override
  User? get currentUser => _user;

  @override
  User? get user => _user;

  @override
  String? get token => _token;

  @override
  bool get isAuthenticated => _token != null;

  @override
  String get userRole => _user.role;
}

/// Records every named route the screen under test navigated to, in order.
///
/// Screens navigate far more than widgets do, and a `pushNamed` against a
/// [MaterialApp] with no route table throws — so without this, half the taps on a
/// screen are untestable.
class RouteLog {
  final List<String> pushed = <String>[];

  /// What each push in [pushed] carried as its `arguments`, at the same index.
  ///
  /// Several screens hand the next one its subject this way — a phone number, a
  /// venue id — and a push that arrives with the wrong argument, or none, fails on
  /// the *next* screen rather than here. Recording it is what makes that assertable.
  final List<Object?> arguments = <Object?>[];

  String? get last => pushed.isEmpty ? null : pushed.last;

  bool get isEmpty => pushed.isEmpty;

  /// Whether [name] was pushed at any point.
  bool sawRoute(String name) => pushed.contains(name);

  /// The arguments the most recent push of [name] carried, or null when it was
  /// never pushed.
  Object? argumentsFor(String name) {
    final index = pushed.lastIndexOf(name);
    return index == -1 ? null : arguments[index];
  }

  Route<dynamic> onGenerateRoute(RouteSettings settings) {
    final name = settings.name ?? '';
    if (name != Navigator.defaultRouteName) {
      pushed.add(name);
      arguments.add(settings.arguments);
    }
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => Scaffold(body: Center(child: Text('route:$name'))),
    );
  }
}

/// Pumps [screen] with a session, the app's real theme and a route table.
///
/// Deliberately does not settle. Every screen here shows an indicator while it
/// loads and several of those animate forever, so settling would time out instead
/// of reporting anything. One `pump()` has happened when this returns, which is the
/// screen's loading state; call [settleData] to reach the loaded one.
///
/// [navigatorKey] is for the screens that navigate through a global key rather than
/// their own context — a notification tap goes through `DeepLink.navigatorKey`,
/// which resolves to null in a tree that does not carry it, and a link that could
/// not be used is indistinguishable from one that was never followed.
Future<RouteLog> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  FakeAuth? auth,
  List<SingleChildWidget> providers = const [],
  double textScale = 1.0,
  Size size = const Size(412, 915),
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final log = RouteLog();
  final Widget scaled = textScale == 1.0
      ? screen
      : Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
            ),
            child: screen,
          ),
        );

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth ?? FakeAuth()),
        ...providers,
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        theme: AppTheme.light,
        home: scaled,
        onGenerateRoute: log.onGenerateRoute,
      ),
    ),
  );
  return log;
}

/// Lets the in-flight fetch complete and the screen rebuild on its result.
///
/// Two pumps rather than one: the first delivers the response to the `await`, the
/// second paints the `setState` that followed it. A single pump leaves a screen
/// showing its spinner and a test asserting on the wrong state.
Future<void> settleData(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 100),
}) async {
  await tester.pump(step);
  await tester.pump(step);
}

/// Asserts every widget [finder] matches is at least [minimum] logical pixels on
/// both axes — the floor the project sets for a tap target.
void expectTapTarget(WidgetTester tester, Finder finder, {double minimum = 48}) {
  for (final element in finder.evaluate()) {
    final size = tester.getSize(find.byElementPredicate((e) => e == element));
    expect(size.width, greaterThanOrEqualTo(minimum),
        reason: 'tap target is ${size.width} wide, under $minimum');
    expect(size.height, greaterThanOrEqualTo(minimum),
        reason: 'tap target is ${size.height} tall, under $minimum');
  }
}

/// Asserts the frame that was just pumped laid out without a `RenderFlex`
/// overflow. Overflow is a paint-time [FlutterError] the binding records rather
/// than throws, so it has to be claimed explicitly.
void expectNoOverflow(WidgetTester tester) {
  expect(tester.takeException(), isNull, reason: 'the layout overflowed');
}

/// Scrolls [finder] into view and taps it.
///
/// A screen taller than the phone it is drawn on keeps part of itself outside the
/// viewport, and `tap` on a widget below the fold reports a miss rather than the
/// assertion the test is about. `enterText` needs none of this: it focuses the field
/// directly instead of aiming a pointer at it.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// Stops overflow reports failing the remainder of the current test.
///
/// An overflow is reported once per relayout, so a screen that overflows as it is
/// built produces another report after every interaction, and whichever test pumps
/// next fails on a report it did not cause. Where the overflow is a known defect that
/// a test of its own already pins, this keeps the rest of the file asserting its own
/// subject. Nothing else is suppressed and the previous handler is restored when the
/// test ends.
void ignoreOverflow() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);
}

/// Asserts the screen is showing a loading indicator of some kind.
///
/// Both indicators are accepted because the tree uses both, and which one a given
/// screen picked is a design choice rather than a contract.
void expectLoading(WidgetTester tester) {
  final spinners = find.byType(CircularProgressIndicator);
  expect(
    spinners.evaluate().isNotEmpty ||
        find.byWidgetPredicate((w) => w.runtimeType.toString() == 'CustomLoader')
            .evaluate()
            .isNotEmpty,
    isTrue,
    reason: 'the screen shows no loading indicator while it fetches',
  );
}
