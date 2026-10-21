import 'dart:async';
import 'package:flutter/widgets.dart';
import '../services/realtime_service.dart';

mixin TrustRefresh<T extends StatefulWidget> on State<T> implements WidgetsBindingObserver {
  StreamSubscription<Map<String, dynamic>>? _trustSubscription;
  StreamSubscription<bool>? _trustConnection;

  void refreshTrust();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _trustSubscription = RealtimeService().trustUpdates.listen((_) {
      if (mounted) refreshTrust();
    });
    _trustConnection = RealtimeService().connection.listen((connected) {
      if (connected && mounted) refreshTrust();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) refreshTrust();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _trustSubscription?.cancel();
    _trustConnection?.cancel();
    super.dispose();
  }
}
