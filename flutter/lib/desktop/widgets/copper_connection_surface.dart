import 'dart:math' as math;
import 'package:flutter/material.dart';

/// The connection screen's light palette stays local to its surfaces.
class ConnectionGlassColors {
  static const ink = Color(0xFF302D2B);
  static const muted = Color(0xFF6C625D);
  static const accent = Color(0xFFB66D44);
  static const information = Color(0xFFF3F1F1);
  static const error = Color(0xFF9E3431);
}

ThemeData copperConnectionTheme(BuildContext context) {
  final base = Theme.of(context);
  OutlineInputBorder outline(Color color, [double width = 1]) =>
      OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width));
  return base.copyWith(
    brightness: Brightness.light,
    colorScheme: const ColorScheme.light(
      primary: ConnectionGlassColors.accent,
      onPrimary: Colors.white,
      surface: ConnectionGlassColors.information,
      onSurface: ConnectionGlassColors.ink,
      error: ConnectionGlassColors.error,
      onError: Colors.white,
    ),
    scaffoldBackgroundColor: ConnectionGlassColors.information,
    cardColor: ConnectionGlassColors.information,
    dialogTheme: base.dialogTheme
        .copyWith(backgroundColor: ConnectionGlassColors.information),
    popupMenuTheme: base.popupMenuTheme.copyWith(
      color: ConnectionGlassColors.information,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xCCFFFFFF))),
    ),
    textTheme: base.textTheme.apply(
        bodyColor: ConnectionGlassColors.ink,
        displayColor: ConnectionGlassColors.ink),
    iconTheme: base.iconTheme.copyWith(color: ConnectionGlassColors.muted),
    disabledColor: const Color(0xFF887E78),
    dividerColor: const Color(0x18776A63),
    dividerTheme: base.dividerTheme
        .copyWith(color: const Color(0x18776A63), thickness: 1),
    tabBarTheme:
        base.tabBarTheme.copyWith(labelColor: ConnectionGlassColors.muted),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xA6FFFFFF),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      labelStyle:
          const TextStyle(color: ConnectionGlassColors.muted, fontSize: 14),
      hintStyle: const TextStyle(color: Color(0xFF82756D), fontSize: 14),
      floatingLabelStyle: const TextStyle(color: ConnectionGlassColors.ink),
      prefixIconColor: ConnectionGlassColors.muted,
      errorStyle: const TextStyle(
          color: ConnectionGlassColors.error, fontSize: 12, height: 1.4),
      errorMaxLines: 4,
      border: outline(const Color(0x4DFFFFFF)),
      enabledBorder: outline(const Color(0x99FFFFFF)),
      disabledBorder: outline(const Color(0x40FFFFFF)),
      focusedBorder: outline(ConnectionGlassColors.accent, 2),
      errorBorder: outline(ConnectionGlassColors.error),
      focusedErrorBorder: outline(ConnectionGlassColors.error, 2),
    ),
    checkboxTheme: base.checkboxTheme.copyWith(
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? ConnectionGlassColors.accent
              : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Colors.white),
      side: const BorderSide(color: Color(0xFF8E7C70), width: 1.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
      backgroundColor: ConnectionGlassColors.accent,
      foregroundColor: Colors.white,
      disabledBackgroundColor: const Color(0xFFD7C7BC),
      disabledForegroundColor: const Color(0xFF70645C),
      minimumSize: const Size(0, 50),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      elevation: 0,
      textStyle: base.textTheme.labelLarge
          ?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    )),
  );
}

class MacGlassColors {
  static const ink = Color(0xFF162943);
  static const accent = Color(0xFF284FD0);
  static const solid = Color(0xFFE8EFF7);
  static const rail = Color(0xA6E6EEF8);
  static const pane = Color(0xA6F5F9FF);
  static const edge = Color(0xA6FFFFFF);
}

ThemeData macGlassTheme(BuildContext context) {
  final base = copperConnectionTheme(context);
  const accent = MacGlassColors.accent;
  return base.copyWith(
    colorScheme: base.colorScheme.copyWith(
      primary: accent,
      surface: MacGlassColors.solid,
      onSurface: MacGlassColors.ink,
    ),
    textTheme: base.textTheme.apply(
        bodyColor: MacGlassColors.ink, displayColor: MacGlassColors.ink),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      fillColor: const Color(0xF2FFFFFF),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: accent, width: 2),
      ),
    ),
    checkboxTheme: base.checkboxTheme.copyWith(
      fillColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) ? accent : Colors.transparent),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: base.elevatedButtonTheme.style?.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.disabled)
                ? const Color(0xFFCDD8EF)
                : accent),
      ),
    ),
    cardTheme: base.cardTheme.copyWith(
      color: MacGlassColors.pane,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: MacGlassColors.edge),
      ),
    ),
  );
}

/// Static white glass over the page's smooth light field. No backdrop sampling,
/// pointer listeners or animation tickers; the form subtree stays stable.
class CopperConnectionSurface extends StatelessWidget {
  final Widget child;
  final bool glassHome;
  const CopperConnectionSurface(
      {super.key, required this.child, this.glassHome = false});

  @override
  Widget build(BuildContext context) {
    if (glassHome) {
      return Theme(
        data: macGlassTheme(context),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: MacGlassColors.pane,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: MacGlassColors.edge),
          ),
          child: child,
        ),
      );
    }
    return Theme(
        data: copperConnectionTheme(context),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0x99FFFFFF), Color(0x73FFFFFF)]),
            border: Border.all(color: const Color(0xB3FFFFFF)),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x107B5B48),
                  blurRadius: 40,
                  spreadRadius: -5,
                  offset: Offset(0, 18))
            ],
          ),
          child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                    gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x40FFFFFF), Color(0x00FFFFFF)],
                        stops: [0, .08])),
                child: Padding(
                    padding: const EdgeInsets.all(1),
                    child: DefaultTextStyle.merge(
                        style:
                            const TextStyle(color: ConnectionGlassColors.ink),
                        child: child)),
              )),
        ),
      );
  }
}

/// Keep saved devices primary, with a compact connection panel alongside them.
/// The existing peer view retains its data, scrolling and action routing.
class CopperConnectionLayout extends StatelessWidget {
  final Widget form;
  final Widget savedConnections;
  final String savedHeading;
  final bool glassHome;
  final bool hasNativeBackdrop;
  const CopperConnectionLayout(
      {super.key,
      required this.form,
      required this.savedConnections,
      required this.savedHeading,
      this.glassHome = false,
      this.hasNativeBackdrop = false});

  @override
  Widget build(BuildContext context) {
    if (glassHome) return _buildGlassHome(context);
    return Theme(
        data: copperConnectionTheme(context),
        child: DecoratedBox(
          decoration: const BoxDecoration(
              gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                Color(0xFFE4C0A6),
                Color(0xFFD4B8AC),
                Color(0xFFEBD7CC)
              ],
                  stops: [
                0,
                .5,
                1
              ])),
          child: CustomPaint(
            painter: const _ConnectionLightArcs(),
            child: LayoutBuilder(builder: (context, constraints) {
              final wide =
                  constraints.maxWidth >= 1000 && constraints.maxHeight >= 480;
              final inset = constraints.maxWidth < 600 ? 18.0 : 28.0;
              final heading = Padding(
                  padding: const EdgeInsets.fromLTRB(2, 4, 2, 22),
                  child: Text(savedHeading,
                      style: const TextStyle(
                          fontSize: 24,
                          color: ConnectionGlassColors.ink,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -.4)));
              final content = wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                          Expanded(
                              child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                heading,
                                Expanded(child: savedConnections)
                              ])),
                          const SizedBox(width: 28),
                          SizedBox(
                              width: 316,
                              child: SingleChildScrollView(child: form)),
                        ])
                  : CustomScrollView(slivers: [
                      SliverToBoxAdapter(child: Center(child: form)),
                      SliverPadding(
                          padding: const EdgeInsets.only(top: 28),
                          sliver: SliverToBoxAdapter(child: heading)),
                      SliverFillRemaining(child: savedConnections),
                    ]);
              return Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1320),
                      child: Padding(
                          padding: EdgeInsets.all(inset), child: content)));
            }),
          ),
        ),
      );
  }

  Widget _buildGlassHome(BuildContext context) => Theme(
        data: macGlassTheme(context),
        child: ColoredBox(
          color: hasNativeBackdrop
              ? const Color(0x24E5EEFC)
              : MacGlassColors.solid,
          child: LayoutBuilder(builder: (context, size) {
            final rail = DecoratedBox(
              decoration: const BoxDecoration(
                color: MacGlassColors.rail,
                border: Border(right: BorderSide(color: MacGlassColors.edge)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 12, 10),
                    child: Text(savedHeading,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        )),
                  ),
                  Expanded(child: savedConnections),
                ],
              ),
            );
            if (size.maxWidth < 720) {
              return CustomScrollView(slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(20),
                  sliver: SliverToBoxAdapter(child: Center(child: form)),
                ),
                SliverFillRemaining(child: rail),
              ]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: (size.maxWidth * .29).clamp(242, 328).toDouble(),
                  child: rail,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          minHeight: math.max(0.0, size.maxHeight - 48)),
                      child: Center(child: form),
                    ),
                  ),
                ),
              ],
            );
          }),
        ),
      );
}

/// Broad, softly diffused white arcs on a static background, not live video.
class _ConnectionLightArcs extends CustomPainter {
  const _ConnectionLightArcs();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = const Color(0x36FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 60
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 28);
    canvas.drawArc(
        Rect.fromLTWH(-size.width * .3, -size.height * .55, size.width * 1.5,
            size.height * 1.1),
        0,
        math.pi,
        false,
        paint);
    paint
      ..color = const Color(0x28FFFFFF)
      ..strokeWidth = 90;
    canvas.drawArc(
        Rect.fromLTWH(
            size.width * .35, size.height * .3, size.width, size.height),
        math.pi,
        math.pi * .7,
        false,
        paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ConnectionLightArcs oldDelegate) => false;
}
