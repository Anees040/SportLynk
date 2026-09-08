// The harness every widget test in this directory pumps through.
//
// Three things have to be arranged before a widget from `lib/widgets/` can be
// rendered honestly, and all three are arranged here so that no test file repeats
// them and none of them can drift apart between files.
//
// First, the theme. Half of what these widgets look like comes from
// [AppTheme.light] rather than from their own code — the input borders, the
// elevated-button shape, the text theme — so pumping a bare [MaterialApp] would
// test a widget that never ships. [pumpApp] always supplies the app's single
// [ThemeData].
//
// Second, fonts. Every label in this tree is a `GoogleFonts.poppins` style, and
// `google_fonts` fetches a missing font over HTTP on first use. In a test that is
// both a network call and a source of nondeterminism, so runtime fetching is
// disabled and the platform default is substituted: the text still lays out, it
// simply lays out in the fallback face. Nothing here asserts on glyph metrics for
// that reason.
//
// Third, routes. Two of the widgets under test navigate rather than render —
// [AuthGuard] redirects a blocked role, the notification bell opens a screen — and
// a `pushNamed` against a [MaterialApp] with no route table throws. [RouteLog]
// answers every name with a marker page and records it, which is what makes
// "where did it send the user" an assertion rather than an inference.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:sportlynk/constants/app_theme.dart';
import 'package:sportlynk/services/realtime_service.dart';

/// Records every named route the widget under test navigated to, in order.
///
/// The log is the whole point: a redirect fired from a post-frame callback leaves
/// no trace in the widget tree, so without this a test could only assert that the
/// splash is still showing — which is also true when the redirect never happened.
class RouteLog {
  final List<String> pushed = <String>[];

  /// The last route pushed, or null when the widget never navigated.
  String? get last => pushed.isEmpty ? null : pushed.last;

  bool get isEmpty => pushed.isEmpty;

  Route<dynamic> onGenerateRoute(RouteSettings settings) {
    final name = settings.name ?? '';
    // The initial route is the widget under test, supplied by the caller; only
    // the navigations the widget itself performs are interesting.
    if (name != Navigator.defaultRouteName) pushed.add(name);
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => Scaffold(body: Center(child: Text('route:$name'))),
    );
  }
}

/// Pumps [child] inside the app's real theme, with [providers] in scope.
///
/// Returns the [RouteLog] so a caller can assert on navigation. Deliberately does
/// not settle: several widgets here animate forever (see [CustomLoader]) and
/// `pumpAndSettle` would time out rather than fail with a useful message.
Future<RouteLog> pumpApp(
  WidgetTester tester,
  Widget child, {
  List<SingleChildWidget> providers = const [],
  double textScale = 1.0,
}) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  final log = RouteLog();
  final Widget scaled = textScale == 1.0
      ? child
      : Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
            ),
            child: child,
          ),
        );
  final app = MaterialApp(
      theme: AppTheme.light,
      // The widget under test is the home route rather than a generated one, so a
      // second `pumpApp` inside one test replaces it instead of leaving the first
      // tree standing behind an already-built route.
      home: scaled,
      onGenerateRoute: log.onGenerateRoute,
    );
  await tester.pumpWidget(
    providers.isEmpty
        ? app
        : MultiProvider(providers: providers, child: app),
  );
  return log;
}

/// Sizes the test surface to the frame this project develops against — a Pixel 7
/// is 412 x 915 logical pixels. Reset on tear-down, so one test cannot hand its
/// viewport to the next.
void useDeviceSurface(WidgetTester tester, {Size size = const Size(412, 915)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.reset();
    RealtimeService().disconnect();
  });
}

/// The rendered size of the single widget [finder] matches.
Size sizeOf(WidgetTester tester, Finder finder) => tester.getSize(finder);

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
/// overflow. Overflow is a paint-time [FlutterError], which the test binding
/// records rather than throwing, so it has to be claimed explicitly.
void expectNoOverflow(WidgetTester tester) {
  expect(tester.takeException(), isNull, reason: 'the layout overflowed');
}
