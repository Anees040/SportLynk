import 'package:flutter/material.dart';

import '../constants/colors.dart';

/// A white, rounded, softly-elevated surface — the standard grouping card for
/// sections stacked on the grey [AppColors.background]. Factored out so every such
/// card casts the one consistent shadow ([AppColors.shadow], the Home screen's
/// existing card tone) rather than a slightly different inline value each time.
///
/// The shadow is drawn by the outer container and the fill by an inner [Material], so
/// a [SwitchListTile] or a column of [ListTile]s passed as the [child] casts its ink
/// ripple on the card itself and has it clipped to the rounded corners. [padding] is
/// null when the child owns its own insets; [onTap] makes the whole card tappable.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  /// An optional outline, for a card that must read as highlighted — such as the
  /// accent border on a team invite. Null leaves the soft shadow to delineate it.
  final BoxBorder? border;

  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 12),
    this.onTap,
    this.border,
  });

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(16));

  @override
  Widget build(BuildContext context) {
    final content =
        padding == null ? child : Padding(padding: padding!, child: child);
    return Container(
      width: double.infinity,
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: _radius,
        border: border,
        boxShadow: const [
          BoxShadow(color: AppColors.shadow, blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Material(
        color: AppColors.cardBg,
        borderRadius: _radius,
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? content : InkWell(onTap: onTap, child: content),
      ),
    );
  }
}
