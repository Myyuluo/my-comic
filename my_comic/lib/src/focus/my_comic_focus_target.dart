import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:my_comic/src/focus/my_comic_focus_controller.dart';

/// TODO-1113 P3: whether mouse click-to-focus should be wired on a focus target.
///
/// Gated on the LOGICAL target platform ([defaultTargetPlatform], so tests can
/// override it) being a desktop OS. Mobile / touch platforms do NOT get click-
/// to-focus: there directional focus navigation is a controller/keyboard affair
/// and a tap is already a plain activation with no ring to carry.
bool get _mouseFocusNavigationEnabledForPlatform {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

class MyComicFocusTarget extends StatefulWidget {
  const MyComicFocusTarget({
    super.key,
    required this.id,
    required this.child,
    this.focusNode,
    this.enabled = true,
    this.autofocus = false,
    this.autoHome = true,
  });

  final MyComicFocusId id;
  final Widget child;
  final FocusNode? focusNode;
  final bool enabled;
  final bool autofocus;

  /// Forwarded to [MyComicFocusTargetEntry.autoHome]: set false on interactive
  /// chrome (e.g. a collapsible settings section header) so passive focus
  /// auto-home skips it in favour of the first content row. Explicit
  /// directional navigation still reaches it.
  final bool autoHome;

  @override
  State<MyComicFocusTarget> createState() => _MyComicFocusTargetState();
}

class MyComicFocusRegistration extends StatefulWidget {
  const MyComicFocusRegistration({
    required this.id,
    required this.focusNode,
    required this.child,
    super.key,
    this.enabled = true,
  });

  final MyComicFocusId id;
  final FocusNode focusNode;
  final Widget child;
  final bool enabled;

  @override
  State<MyComicFocusRegistration> createState() =>
      _MyComicFocusRegistrationState();
}

class _MyComicFocusRegistrationState extends State<MyComicFocusRegistration> {
  late final Object _owner = Object();
  MyComicFocusController? _controller;
  BuildContext? _targetContext;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = MyComicFocusRoot.maybeControllerOf(context);
    _register();
  }

  @override
  void didUpdateWidget(MyComicFocusRegistration oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool identityChanged = oldWidget.id != widget.id ||
        !identical(oldWidget.focusNode, widget.focusNode);
    if (identityChanged) {
      _unregister(oldWidget.id, oldWidget.focusNode);
    }
    _register();
  }

  @override
  void dispose() {
    _unregister(widget.id, widget.focusNode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _MyComicFocusTargetAnchor(
      onReady: (BuildContext targetContext) {
        _targetContext = targetContext;
        _register(repairBeforeNextFrame: true);
      },
      child: widget.child,
    );
  }

  void _register({bool repairBeforeNextFrame = false}) {
    final MyComicFocusController? controller = _controller;
    if (controller == null) return;
    final BuildContext? targetContext = _targetContext;
    if (targetContext == null) return;
    controller.register(
      MyComicFocusTargetEntry(
        id: widget.id,
        focusNode: widget.focusNode,
        context: targetContext,
        enabled: widget.enabled,
        owner: _owner,
      ),
      repairBeforeNextFrame: repairBeforeNextFrame,
    );
  }

  void _unregister(MyComicFocusId id, FocusNode node) {
    _controller?.unregister(id, node, _owner);
  }
}

class _MyComicFocusTargetState extends State<MyComicFocusTarget> {
  late FocusNode _ownedNode;
  late final Object _owner = Object();
  MyComicFocusController? _controller;
  FocusNode? _registeredNode;
  BuildContext? _targetContext;

  FocusNode get _focusNode => widget.focusNode ?? _ownedNode;

  @override
  void initState() {
    super.initState();
    _ownedNode = FocusNode(debugLabel: widget.id.value);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller = MyComicFocusRoot.maybeControllerOf(context);
    _register();
  }

  @override
  void didUpdateWidget(MyComicFocusTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool identityChanged = oldWidget.id != widget.id ||
        !identical(oldWidget.focusNode, widget.focusNode);
    if (identityChanged) {
      _unregister(oldWidget.id, _registeredNode ?? _focusNode);
    }
    _register();
  }

  @override
  void dispose() {
    _unregister(widget.id, _registeredNode ?? _focusNode);
    _ownedNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget focus = Focus(
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      canRequestFocus: widget.enabled,
      skipTraversal: !widget.enabled,
      child: _MyComicFocusTargetAnchor(
        onReady: (BuildContext targetContext) {
          _targetContext = targetContext;
          _register(repairBeforeNextFrame: true);
        },
        child: widget.child,
      ),
    );
    // TODO-1113 P3: on desktop, a mouse click on a focus target should carry
    // directional-navigation focus here so subsequent keyboard/gamepad traversal
    // continues from what the user clicked. The [Listener] does NOT consume the
    // event (child InkWell/GestureDetector still activates as usual — no double
    // fire) and does NOT invoke ActivateIntent; it only moves focus. Restricted
    // to real mouse pointers and to enabled targets; touch/stylus and mobile
    // platforms keep the old plain-tap behaviour.
    if (!widget.enabled || !_mouseFocusNavigationEnabledForPlatform) {
      return focus;
    }
    return Listener(
      onPointerDown: _handleMousePointerDown,
      child: focus,
    );
  }

  /// TODO-1113 P3: carries focus to this target on a mouse press. Mouse-only so
  /// touch input on a desktop touchscreen keeps plain-tap behaviour; activation
  /// is left entirely to the child's own tap handling to avoid double firing.
  void _handleMousePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    _controller?.requestById(widget.id);
  }

  void _register({bool repairBeforeNextFrame = false}) {
    final MyComicFocusController? controller = _controller;
    if (controller == null) return;
    final BuildContext? targetContext = _targetContext;
    if (targetContext == null) return;
    _registeredNode = _focusNode;
    controller.register(
      MyComicFocusTargetEntry(
        id: widget.id,
        focusNode: _focusNode,
        context: targetContext,
        enabled: widget.enabled,
        owner: _owner,
        autoHome: widget.autoHome,
      ),
      repairBeforeNextFrame: repairBeforeNextFrame,
    );
  }

  void _unregister(MyComicFocusId id, FocusNode node) {
    _controller?.unregister(id, node, _owner);
  }
}

/// Declaratively registers one or more directional anchors on the ambient
/// [MyComicFocusController] for the lifetime of [child]. An anchor makes pressing
/// a direction while [source] is focused jump to an explicit target focusId,
/// short-circuiting geometry (see [MyComicFocusController.registerDirectionalAnchor]).
/// Outside a [MyComicFocusRoot] it is an inert pass-through.
class MyComicFocusDirectionalAnchor extends StatefulWidget {
  const MyComicFocusDirectionalAnchor({
    required this.source,
    required this.anchors,
    required this.child,
    super.key,
  });

  final MyComicFocusId source;

  /// direction -> target focusId for [source].
  final Map<MyComicFocusDirection, MyComicFocusId> anchors;
  final Widget child;

  @override
  State<MyComicFocusDirectionalAnchor> createState() =>
      _MyComicFocusDirectionalAnchorState();
}

class _MyComicFocusDirectionalAnchorState
    extends State<MyComicFocusDirectionalAnchor> {
  MyComicFocusController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MyComicFocusController? next =
        MyComicFocusRoot.maybeControllerOf(context);
    if (!identical(next, _controller)) {
      _clear();
      _controller = next;
    }
    _apply();
  }

  @override
  void didUpdateWidget(MyComicFocusDirectionalAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        !_sameAnchors(oldWidget.anchors, widget.anchors)) {
      _clearFor(oldWidget.source, oldWidget.anchors);
      _apply();
    }
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  bool _sameAnchors(
    Map<MyComicFocusDirection, MyComicFocusId> a,
    Map<MyComicFocusDirection, MyComicFocusId> b,
  ) {
    if (a.length != b.length) return false;
    for (final MapEntry<MyComicFocusDirection, MyComicFocusId> e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  void _apply() {
    final MyComicFocusController? controller = _controller;
    if (controller == null) return;
    widget.anchors
        .forEach((MyComicFocusDirection direction, MyComicFocusId target) {
      controller.registerDirectionalAnchor(widget.source, direction, target);
    });
  }

  void _clear() => _clearFor(widget.source, widget.anchors);

  void _clearFor(
    MyComicFocusId source,
    Map<MyComicFocusDirection, MyComicFocusId> anchors,
  ) {
    final MyComicFocusController? controller = _controller;
    if (controller == null) return;
    anchors.forEach((MyComicFocusDirection direction, MyComicFocusId target) {
      controller.unregisterDirectionalAnchor(source, direction, target);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _MyComicFocusTargetAnchor extends StatefulWidget {
  const _MyComicFocusTargetAnchor({
    required this.onReady,
    required this.child,
  });

  final ValueChanged<BuildContext> onReady;
  final Widget child;

  @override
  State<_MyComicFocusTargetAnchor> createState() =>
      _MyComicFocusTargetAnchorState();
}

class _MyComicFocusTargetAnchorState extends State<_MyComicFocusTargetAnchor> {
  final GlobalKey _anchorKey = GlobalKey();
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleReady();
  }

  @override
  void didUpdateWidget(_MyComicFocusTargetAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleReady();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleReady();
    return _MyComicFocusRenderAnchor(
      key: _anchorKey,
      child: widget.child,
    );
  }

  void _scheduleReady() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final BuildContext? anchorContext = _anchorKey.currentContext;
      if (anchorContext != null) {
        widget.onReady(anchorContext);
      }
    });
  }
}

class _MyComicFocusRenderAnchor extends SingleChildRenderObjectWidget {
  const _MyComicFocusRenderAnchor({super.key, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderProxyBox();
  }
}
