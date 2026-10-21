import 'package:flutter/material.dart';

import '../constants/colors.dart';

ScrollBehavior stableScrollBehavior(BuildContext context) {
  return ScrollConfiguration.of(
    context,
  ).copyWith(overscroll: false, physics: const ClampingScrollPhysics());
}

class StableRefreshIndicator extends StatelessWidget {
  const StableRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
    this.color = AppColors.accent,
  });

  final RefreshCallback onRefresh;
  final Widget child;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      behavior: stableScrollBehavior(context),
      child: RefreshIndicator(color: color, onRefresh: onRefresh, child: child),
    );
  }
}
