import 'dart:async';

import 'package:flutter/widgets.dart';

import '../services/realtime_service.dart';

/// Auto-refresh on the socket's offline→online edge.
///
/// A screen that reads from the network mixes this in and implements
/// [onReconnect] — usually its own load method — so data missed while offline
/// fills itself in the moment connectivity returns, without the user pulling to
/// refresh. Pull-to-refresh stays as the manual fallback.
///
/// The subscription is opened in [initState] and closed in [dispose] through the
/// mixin's own super calls, so a host only needs `with ReconnectRefresh<Widget>`
/// and an [onReconnect] body; it must still call `super.initState()` and
/// `super.dispose()` as every [State] already does.
mixin ReconnectRefresh<T extends StatefulWidget> on State<T> {
  StreamSubscription<bool>? _reconnectSub;

  /// Invoked on each offline→online transition while the screen is mounted. The
  /// host guards it with any freshness condition of its own.
  void onReconnect();

  @override
  void initState() {
    super.initState();
    _reconnectSub = RealtimeService().connection.listen((up) {
      if (up && mounted) onReconnect();
    });
  }

  @override
  void dispose() {
    _reconnectSub?.cancel();
    super.dispose();
  }
}
