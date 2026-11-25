import 'dart:async';

import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/iphone_duo.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/pages/home/home_layout.dart';
import 'package:better_keep/pages/note_editor/note_editor.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Opens [note] beside the list when [context] is on the home screen of an open
/// iPhone Duo, and as a page of its own everywhere else.
///
/// The result completes when the note closes, or at once if another note was
/// asked for before this one could open.
Future<dynamic> openNote(
  BuildContext context,
  Note note, {
  bool autoFocus = false,
  bool deleteIfUnchanged = false,
}) {
  final host = NotePaneHost._maybeOf(context);
  if (host != null && host._canOpen) {
    return host._open(
      _NoteRequest(note, autoFocus, deleteIfUnchanged, Completer<dynamic>()),
    );
  }
  return showPage(
    context,
    NoteEditor(
      note: note,
      autoFocus: autoFocus,
      deleteIfUnchanged: deleteIfUnchanged,
    ),
    allowFullScreen: true,
  );
}

/// Opens [page] from an open note. Where there is room for two panes the note
/// moves to the start side and [page] takes its place.
///
/// The note is only for reading there unless [noteStaysEditable]. A page that
/// also writes the text of the note must not set it.
Future<dynamic> openBesideNote(
  BuildContext context,
  Widget page, {
  bool noteStaysEditable = false,
}) {
  final note = ModalRoute.of(context);
  if (note is _NotePaneRoute && note.isCurrent) {
    return note._open(page, noteStaysEditable);
  }
  // A second tap on the way to the first page.
  if (note is _NotePaneRoute && note._besideIsOpen) return Future.value();
  return showPage(context, page, allowFullScreen: true);
}

/// Makes room for an open note beside the home screen.
///
/// The editor stays a route whose position follows the window, so folding or
/// resizing never rebuilds it, and closing it still runs its own save. While
/// the note is beside the list, [child] sees a [MediaQuery] of the list's size.
class NotePaneHost extends StatefulWidget {
  const NotePaneHost({super.key, required this.child});

  final Widget child;

  static NotePaneHostState? _maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_NotePaneScope>()?.host;

  /// Whether a note is open beside the list. Rebuilds [context] on change.
  static bool isSideBySide(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_NotePaneScope>()
          ?.sideBySide ??
      false;

  /// Whether [context] is in a note with another page open beside it. Rebuilds
  /// [context] on change.
  static bool hasPageBeside(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_BesideScope>()
          ?.hasPageBeside ??
      false;

  /// Whether that page makes the note read-only.
  static bool isReference(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_BesideScope>()?.isReference ??
      false;

  /// Closes the page beside a note, as its back button would.
  static Future<void> closePageBeside(BuildContext context) async {
    final note = ModalRoute.of(context);
    if (note is _NotePaneRoute) await note._closeBeside();
  }

  /// Whether images in an open note may fly into the page they open. They stay
  /// put when that page opened beside the note.
  static bool heroesEnabled(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_BesideScope>()
          ?.heroesEnabled ??
      true;

  /// The note that is open from the list of [context], if any, until it has
  /// quite gone.
  static Note? openNoteOf(BuildContext context) {
    return _maybeOf(context)?._route?.request.note;
  }

  /// The copy of [note] that the open editor holds, or else [note]. Saving
  /// another copy could put back the text as it was before an edit.
  static Note currentCopyOf(BuildContext context, Note note) {
    final open = openNoteOf(context);
    return open != null && open.id != null && open.id == note.id ? open : note;
  }

  /// Closes the note beside the list of [context], saving it first. False if it
  /// stays open, because it could not be saved. Null if there is none to close.
  ///
  /// Pages of the list can sign out, erase or rewrite notes, which must not
  /// happen under an editor. On other devices the editor covers the list.
  static Future<bool>? closeNote(BuildContext context) {
    final host = _maybeOf(context);
    return (host?._route?.isCurrent ?? false) ? host!._closeNote() : null;
  }

  @override
  State<NotePaneHost> createState() => NotePaneHostState();
}

class NotePaneHostState extends State<NotePaneHost> {
  static final _openNotes = Expando<_NotePaneRoute>();

  /// The open note, until its closing transition has finished. The list keeps
  /// its place meanwhile.
  _NotePaneRoute? _route;
  _NoteRequest? _next;
  bool _switching = false;
  NotePaneLayout? _layout;

  /// Other pages on top of home keep opening notes as pages of their own.
  bool get _canOpen =>
      mounted &&
      ((ModalRoute.of(context)?.isCurrent ?? false) ||
          (_route?.isCurrent ?? false) ||
          _switching);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The home screen can be built anew under a note, as when a session ends.
    if (_route == null && isIPhoneDuo) {
      final open = _openNotes[Navigator.of(context)];
      if (open != null && open.isActive) _follow(open);
    }
    _layout = NotePaneLayout.of(
      MediaQuery.of(context),
      Directionality.of(context),
    );
    final route = _route;
    if (route == null) return;
    // The overlay cannot change while it is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(route, _route)) {
        route._setSideBySide(_layout != null);
      }
    });
  }

  Future<dynamic> _open(_NoteRequest request) {
    final route = _route;
    if (!_switching &&
        route != null &&
        route.isActive &&
        route.request.isSameNote(request)) {
      return route.popped;
    }
    _next?.done.complete();
    _next = request;
    if (!_switching) unawaited(_switch());
    return request.done.future;
  }

  /// Opens the latest request once the note before it has been saved. A note
  /// that could not be saved stays open, and the request is dropped.
  Future<void> _switch() async {
    _switching = true;
    try {
      while (_next != null && mounted) {
        if (!await _closeNote()) {
          _next?.done.complete();
          _next = null;
          return;
        }
        final request = _next;
        _next = null;
        if (request == null || !mounted) return;
        _push(request);
      }
    } finally {
      _switching = false;
    }
  }

  void _push(_NoteRequest request) {
    final route = _NotePaneRoute(request, sideBySide: _layout != null);
    final navigator = Navigator.of(context);
    _openNotes[navigator] = route;
    setState(() => _follow(route));
    unawaited(
      navigator.push(route).whenComplete(() {
        if (!request.done.isCompleted) request.done.complete();
      }),
    );
  }

  void _follow(_NotePaneRoute route) {
    _route = route;
    unawaited(
      route.completed.whenComplete(() {
        if (mounted && identical(_route, route)) setState(() => _route = null);
      }),
    );
  }

  Future<bool> _closeNote() async {
    final route = _route;
    if (route == null || !route.isActive) return true;
    if (!route.isCurrent) return false;
    // A note that has only just been pushed has no editor to close yet.
    if (!route.editor.isAttached) {
      await WidgetsBinding.instance.endOfFrame;
      if (!route.isActive) return true;
    }
    if (!await route.editor.close()) return false;
    await route.popped;
    return true;
  }

  @override
  void dispose() {
    _next?.done.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Other devices keep their own pages, with nothing around the home screen.
    if (!isIPhoneDuo) return widget.child;
    final layout = _layout;
    final sideBySide = _route != null && layout != null;
    final ltr = Directionality.of(context) == TextDirection.ltr;
    final media = MediaQuery.of(context);
    // Keep one tree shape so that folding does not rebuild the list's state.
    return _NotePaneScope(
      host: this,
      sideBySide: sideBySide,
      child: ColoredBox(
        // Seen beside the list while a note arrives or leaves.
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: SizedBox(
            width: sideBySide ? layout.listWidth : null,
            child: MediaQuery(
              data: sideBySide
                  ? media
                        .removePadding(removeRight: ltr, removeLeft: !ltr)
                        .copyWith(
                          size: Size(layout.listWidth, media.size.height),
                        )
                  : media,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

class _NotePaneScope extends InheritedWidget {
  const _NotePaneScope({
    required this.host,
    required this.sideBySide,
    required super.child,
  });

  final NotePaneHostState host;
  final bool sideBySide;

  @override
  bool updateShouldNotify(_NotePaneScope old) => sideBySide != old.sideBySide;
}

class _BesideScope extends InheritedWidget {
  const _BesideScope({
    required this.hasPageBeside,
    required this.isReference,
    required this.heroesEnabled,
    required super.child,
  });

  final bool hasPageBeside;
  final bool isReference;
  final bool heroesEnabled;

  @override
  bool updateShouldNotify(_BesideScope old) =>
      hasPageBeside != old.hasPageBeside ||
      isReference != old.isReference ||
      heroesEnabled != old.heroesEnabled;
}

class _NoteRequest {
  _NoteRequest(this.note, this.autoFocus, this.deleteIfUnchanged, this.done);

  final Note note;
  final bool autoFocus;
  final bool deleteIfUnchanged;
  final Completer<dynamic> done;

  bool isSameNote(_NoteRequest other) =>
      identical(note, other.note) ||
      (note.id != null && note.id == other.note.id);
}

/// Where a page sits in the window, and the width its content is laid out at.
typedef _Pane = ({
  double start,
  double end,
  double width,
  bool atStart,
  Color? color,
});

/// A page that fills the window, or only its end side when there is room for
/// another pane beside it.
abstract class _PaneRoute extends PageRoute<dynamic> {
  _PaneRoute({required this._sideBySide});

  bool _sideBySide;

  void _setSideBySide(bool value) {
    if (value == _sideBySide || !isActive) return;
    _sideBySide = value;
    changedInternalState();
    if (animation?.isCompleted ?? false) overlayEntries.first.opaque = opaque;
  }

  /// The pane beside this one is only built while it can be seen.
  @override
  bool get opaque => !_sideBySide;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  /// The pane beside this one stays usable.
  @override
  Widget buildModalBarrier() =>
      _sideBySide ? const SizedBox.shrink() : super.buildModalBarrier();

  _Pane _pane(BuildContext context, NotePaneLayout layout) => (
    start: layout.listWidth,
    end: 0,
    width: layout.paneWidth,
    atStart: false,
    color: null,
  );

  /// Whether a page that covers this one moves it aside as a pane, rather than
  /// with the theme's transition.
  bool get _movesAside => false;

  bool get _hasPageBeside => false;

  bool get _isReference => false;

  bool get _heroesEnabled => true;

  final Set<int> _pointers = {};

  bool get _ignoresPointers => false;

  void _onPointerDown(PointerDownEvent event) => _pointers.add(event.pointer);

  void _onPointerEnd(PointerEvent event) => _pointers.remove(event.pointer);

  MediaQueryData _adjust(MediaQueryData media) => media;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => AnimatedBuilder(
    animation: secondaryAnimation,
    builder: (context, _) {
      final window = MediaQuery.of(context);
      final direction = Directionality.of(context);
      final layout = NotePaneLayout.of(window, direction);
      final media = _adjust(window);
      final pane = layout == null ? null : _pane(context, layout);
      final insetStart = pane != null && !pane.atStart;
      final insetEnd = pane != null && pane.atStart;
      final ltr = direction == TextDirection.ltr;
      // The transition is inside the pane because it takes every tap in its
      // area. One tree shape keeps the page's state across a fold.
      return Padding(
        padding: EdgeInsetsDirectional.only(
          start: pane?.start ?? 0,
          end: pane?.end ?? 0,
        ),
        child: ClipRect(
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: pane == null || pane.start == 0
                  ? null
                  : BorderDirectional(
                      start: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
            ),
            child: ColoredBox(
              color: pane?.color ?? Colors.transparent,
              child: OverflowBox(
                alignment: AlignmentDirectional.centerStart,
                minWidth: pane?.width,
                maxWidth: pane?.width,
                child: MediaQuery(
                  data: pane == null
                      ? media
                      : media
                            .removePadding(
                              removeLeft: ltr ? insetStart : insetEnd,
                              removeRight: ltr ? insetEnd : insetStart,
                            )
                            .copyWith(
                              size: Size(pane.width, media.size.height),
                            ),
                  child: Theme.of(context).pageTransitionsTheme
                      .buildTransitions(
                        this,
                        context,
                        animation,
                        pane != null && _movesAside
                            ? kAlwaysDismissedAnimation
                            : secondaryAnimation,
                        _BesideScope(
                          hasPageBeside: _hasPageBeside,
                          isReference: _isReference,
                          heroesEnabled: _heroesEnabled,
                          child: _PointerGate(
                            isClosed: () => _ignoresPointers,
                            child: Listener(
                              onPointerDown: _onPointerDown,
                              onPointerUp: _onPointerEnd,
                              onPointerCancel: _onPointerEnd,
                              child: child,
                            ),
                          ),
                        ),
                      ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Takes the touches of [child] away from it while [isClosed].
class _PointerGate extends SingleChildRenderObjectWidget {
  const _PointerGate({required this.isClosed, required super.child});

  final bool Function() isClosed;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPointerGate(isClosed);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPointerGate renderObject,
  ) => renderObject.isClosed = isClosed;
}

class _RenderPointerGate extends RenderProxyBox {
  _RenderPointerGate(this.isClosed);

  bool Function() isClosed;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      isClosed()
      ? size.contains(position)
      : super.hitTest(result, position: position);
}

class _NotePaneRoute extends _PaneRoute {
  _NotePaneRoute(this.request, {required super.sideBySide});

  final _NoteRequest request;
  final NoteEditorHandle editor = NoteEditorHandle();

  /// The page beside the note, until its closing transition has finished.
  _BesideNoteRoute? _beside;
  bool _besideIsOpen = false;

  @override
  void install() {
    super.install();
    AuthService.signOutStage.addListener(_onSignOut);
  }

  @override
  void dispose() {
    AuthService.signOutStage.removeListener(_onSignOut);
    super.dispose();
  }

  /// The screen that shows the progress of a sign-out takes the whole app down,
  /// and this note with it. A sign-out in the background may finish before that
  /// screen is ever built, and the note must not reach the next account.
  void _onSignOut() {
    if (AuthService.signOutStage.value == null || !isActive) return;
    final beside = _beside;
    if (beside != null && beside.isActive) navigator!.removeRoute(beside);
    navigator!.removeRoute(this);
  }

  Future<dynamic> _open(Widget page, bool noteStaysEditable) {
    final route = _BesideNoteRoute(
      this,
      page,
      noteStaysEditable: noteStaysEditable,
      sideBySide: _sideBySide,
    );
    _beside = route;
    _besideIsOpen = true;
    final result = navigator!.push(route);
    changedInternalState();
    unawaited(
      route.popped.whenComplete(() {
        _besideIsOpen = false;
        if (isActive) changedInternalState();
      }),
    );
    unawaited(
      route.completed.whenComplete(() {
        if (!identical(_beside, route)) return;
        _beside = null;
        if (isActive) changedInternalState();
      }),
    );
    return result;
  }

  @override
  void _setSideBySide(bool value) {
    super._setSideBySide(value);
    _beside?._setSideBySide(value);
  }

  Future<void> _closeBeside() async {
    if (_beside?.isCurrent ?? false) await navigator?.maybePop();
  }

  /// A hand that rests on the note must not act on it while the other uses the
  /// page beside it.
  @override
  bool get _ignoresPointers =>
      _besideIsOpen && (_beside?._pointers.isNotEmpty ?? false);

  void _onBesidePointerDown() {
    _pointers.toList().forEach(GestureBinding.instance.cancelPointer);
    _giveFocusToBeside();
  }

  void _giveFocusToBeside() {
    final focused = FocusManager.instance.primaryFocus?.context;
    final page = _beside?.subtreeContext;
    if (!_besideIsOpen || focused == null || page == null) return;
    if (identical(ModalRoute.of(focused), this)) {
      FocusScope.of(page).requestFocus();
    }
  }

  @override
  bool get _movesAside => _beside != null;

  @override
  bool get _hasPageBeside => _sideBySide && _besideIsOpen;

  @override
  bool get _isReference =>
      _hasPageBeside && !(_beside?.noteStaysEditable ?? false);

  /// A flight that started must also finish, so this does not follow a fold.
  @override
  bool get _heroesEnabled => !(_beside?.openedBeside ?? false);

  @override
  _Pane _pane(BuildContext context, NotePaneLayout layout) {
    final progress = secondaryAnimation;
    if (!_movesAside || progress == null || progress.isDismissed) {
      return super._pane(context, layout);
    }
    // Match the page that is arriving or leaving beside the note, so that no
    // gap opens between them.
    final closing = progress.status == AnimationStatus.reverse;
    final value = navigator?.userGestureInProgress ?? false
        ? progress.value
        : (closing
                  ? Curves.fastEaseInToSlowEaseOut.flipped
                  : Curves.fastEaseInToSlowEaseOut)
              .transform(progress.value);
    final color = request.note.color;
    return (
      start: layout.listWidth * (1 - value),
      end: layout.paneWidth * value,
      // Lay the note out once, at the size it is going to.
      width: closing ? layout.paneWidth : layout.listWidth,
      atStart: !closing,
      color: color == Colors.transparent
          ? Theme.of(context).colorScheme.surface
          : color,
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => NoteEditor(
    note: request.note,
    autoFocus: request.autoFocus,
    deleteIfUnchanged: request.deleteIfUnchanged,
    handle: editor,
  );
}

/// A page that opened from a note, beside it when there is room.
class _BesideNoteRoute extends _PaneRoute {
  _BesideNoteRoute(
    this.note,
    this.page, {
    required this.noteStaysEditable,
    required super.sideBySide,
  }) : openedBeside = sideBySide;

  final _NotePaneRoute note;
  final Widget page;
  final bool noteStaysEditable;
  final bool openedBeside;

  @override
  void _onPointerDown(PointerDownEvent event) {
    super._onPointerDown(event);
    if (_sideBySide) note._onBesidePointerDown();
  }

  /// The keyboard belongs to the note, so this page keeps its size.
  @override
  MediaQueryData _adjust(MediaQueryData media) => noteStaysEditable
      ? media.copyWith(
          viewInsets: media.viewInsets.copyWith(bottom: 0),
          padding: media.padding.copyWith(bottom: media.viewPadding.bottom),
        )
      : media;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => page;
}
