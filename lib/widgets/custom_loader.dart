import 'package:flutter/material.dart';
import '../../constants/colors.dart';

class CustomLoader extends StatefulWidget {
  final double size;
  final Color color;

  const CustomLoader({super.key, this.size = 48.0, this.color = AppColors.accent});

  @override
  State<CustomLoader> createState() => _CustomLoaderState();
}

class _CustomLoaderState extends State<CustomLoader> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, child) {
          return Stack(
            alignment: Alignment.center,
            children: [
              // Outer pulsing ring
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.color.withValues(alpha: 1 - _ctrl.value),
                    width: 3 * (1 - _ctrl.value),
                  ),
                ),
              ),
              // Inner spinning semi-circle
              Transform.rotate(
                angle: _ctrl.value * 2 * 3.14159,
                child: SizedBox(
                  width: widget.size * 0.7,
                  height: widget.size * 0.7,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(widget.color),
                    backgroundColor: widget.color.withValues(alpha: 0.2),
                  ),
                ),
              ),
              // Center logo or dot
              Container(
                width: widget.size * 0.25,
                height: widget.size * 0.25,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
