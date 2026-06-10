import 'package:flutter/material.dart';

/// Switches between sidebar / rail / drawer chrome around `detail` based on
/// the available width. Spec §6.1 breakpoints:
///   - >= 800: sidebar (240px) + detail
///   - >= 600 && < 800: rail + detail
///   - < 600: drawer + full-screen detail
///
/// Uses `LayoutBuilder` not `MediaQuery` so resize events on the desktop
/// shell propagate without lag.
class LayoutScaffold extends StatelessWidget {
  const LayoutScaffold({
    super.key,
    required this.sidebar,
    required this.rail,
    required this.drawer,
    required this.detail,
  });

  final Widget sidebar;
  final Widget rail;
  final Widget drawer;
  final Widget detail;

  static const double sidebarBreakpoint = 800;
  static const double railBreakpoint = 600;
  static const double sidebarWidth = 240;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= sidebarBreakpoint) {
          return Row(
            children: [
              SizedBox(width: sidebarWidth, child: sidebar),
              Expanded(child: detail),
            ],
          );
        }
        // Rail + drawer branches land in T5 + T6.
        return detail;
      },
    );
  }
}
