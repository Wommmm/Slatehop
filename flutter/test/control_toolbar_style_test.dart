import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/copper_glass_controls.dart';

Widget fixture(Widget child, {bool reduceMotion = false, bool ticking = true}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: TickerMode(
        enabled: ticking,
        child: Center(child: child),
      ),
    ),
  );
}

class CountBuilds extends StatelessWidget {
  final VoidCallback onBuild;
  final Widget child;
  const CountBuilds({super.key, required this.onBuild, required this.child});
  @override
  Widget build(BuildContext context) {
    onBuild();
    return child;
  }
}

void main() {
  testWidgets(
      'local hover leaves actions, keyboard focus and child builds intact',
      (tester) async {
    var presses = 0;
    var builds = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final controls = CountBuilds(
      onBuild: () => builds++,
      child: TextButton(
        focusNode: focus,
        onPressed: () => presses++,
        child: const Text('Control'),
      ),
    );
    await tester.pumpWidget(fixture(CopperGlassControls(child: controls)));
    final originalBuilds = builds;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Control')));
    await tester.pump();
    await mouse.moveBy(const Offset(12, 0));
    await tester.pump();
    expect(builds, originalBuilds);
    await tester.tap(find.text('Control'));
    expect(presses, 1);
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(presses, 2);
    final focusedElement = focus.context;
    await tester.pumpWidget(fixture(CopperGlassControls(
      interactive: false,
      child: controls,
    )));
    expect(focus.context, same(focusedElement));
    expect(focus.hasFocus, isTrue);
    await mouse.removePointer();
  });

  testWidgets(
      'glass shell preserves menu, scroll and drag targets in narrow dock',
      (tester) async {
    var actions = 0;
    var drags = 0;
    await tester.pumpWidget(fixture(SizedBox(
      width: 150,
      child: CopperGlassControls(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Draggable<int>(
              data: 1,
              onDragStarted: () => drags++,
              feedback: const Icon(Icons.drag_indicator),
              child: const SizedBox(
                key: ValueKey('grip'),
                width: 32,
                height: 40,
                child: Icon(Icons.drag_indicator),
              ),
            ),
            MenuBar(children: [
              SubmenuButton(
                menuChildren: [
                  MenuItemButton(
                      onPressed: () => actions++, child: const Text('Action'))
                ],
                child: const Text('Menu'),
              ),
            ]),
            const SizedBox(width: 180, child: Text('Scrollable controls')),
          ]),
        ),
      ),
    )));
    await tester.tap(find.text('Menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Action'));
    await tester.pumpAndSettle();
    expect(actions, 1);
    await tester.drag(find.byKey(const ValueKey('grip')), const Offset(40, 40));
    await tester.pumpAndSettle();
    expect(drags, 1);
    await tester.drag(
        find.byType(SingleChildScrollView).first, const Offset(-130, 0));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(find
        .descendant(
          of: find.byType(CopperGlassControls),
          matching: find.byType(Scrollable),
        )
        .first);
    expect(scrollable.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion is static and hidden chrome schedules no frames',
      (tester) async {
    Widget shell() => const CopperGlassControls(
          child:
              SizedBox(width: 200, height: 44, child: Text('Static controls')),
        );
    await tester.pumpWidget(fixture(shell(), reduceMotion: true));
    MouseRegion region() => tester.widget<MouseRegion>(find.descendant(
          of: find.byType(CopperGlassControls),
          matching: find.byType(MouseRegion),
        ));
    expect(region().onHover, isNull);
    await tester.pumpWidget(fixture(shell(), ticking: false));
    expect(region().onHover, isNull);
    await tester.pumpWidget(fixture(Offstage(child: shell())));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical dock keeps its original control size', (tester) async {
    await tester.pumpWidget(fixture(const CopperGlassControls(
      child: SizedBox(width: 32, height: 360),
    )));
    // Only the same 1px border inset used by the existing toolbar is added.
    expect(
        tester.getSize(find.byType(CopperGlassControls)), const Size(34, 362));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pointer light changes only pixels inside the dock',
      (tester) async {
    final canvasKey = GlobalKey();
    final shellKey = GlobalKey();
    await tester.pumpWidget(fixture(RepaintBoundary(
      key: canvasKey,
      child: ColoredBox(
        color: const Color(0xFF101820),
        child: SizedBox(
          width: 300,
          height: 100,
          child: Center(
              child: CopperGlassControls(
            key: shellKey,
            child: const SizedBox(
              width: 180,
              height: 44,
              child: Center(
                  child: SizedBox(
                width: 32,
                height: 20,
                child: ColoredBox(color: Color(0xFFEEEEEE)),
              )),
            ),
          )),
        ),
      ),
    )));
    final boundary =
        canvasKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    Future<List<int>> pixels() async {
      return (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final result = bytes!.buffer.asUint8List().toList();
        image.dispose();
        return result;
      }))!;
    }

    final initial = await pixels();
    final canvasRect = tester.getRect(find.byKey(canvasKey));
    final dockRect =
        tester.getRect(find.byKey(shellKey)).shift(-canvasRect.topLeft);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(shellKey)));
    await tester.pump();
    final hovered = await pixels();
    // Opaque controls must retain their painted content when only the light
    // background repaints, including in an offscreen fixture capture.
    final center = (50 * 300 + 150) * 4;
    expect(initial.sublist(center, center + 4), [238, 238, 238, 255]);
    expect(hovered.sublist(center, center + 4), [238, 238, 238, 255]);
    var changedInside = 0;
    var changedOutside = 0;
    for (var y = 0; y < 100; y++) {
      for (var x = 0; x < 300; x++) {
        final index = (y * 300 + x) * 4;
        final changed =
            List.generate(4, (c) => initial[index + c] != hovered[index + c])
                .any((c) => c);
        if (changed) {
          if (dockRect.contains(Offset(x + .5, y + .5))) {
            changedInside++;
          } else {
            changedOutside++;
          }
        }
      }
    }
    expect(changedInside, greaterThan(0));
    expect(changedOutside, 0);
    await mouse.removePointer();
  });
}
