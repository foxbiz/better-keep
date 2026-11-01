import 'dart:async';

import 'package:better_keep/components/image_share_progress.dart';
import 'package:better_keep/l10n/app_localization_config.dart';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/services/intent_handler_service.dart';
import 'package:better_keep/services/shared_image_note_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SharingIntent sharing;
  late IntentHandlerService handler;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    sharing = _SharingIntent();
    handler = IntentHandlerService(sharingIntent: sharing);
  });
  tearDown(() {
    handler.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'progress covers import, but not startup, without adding a route',
    (tester) async {
      final ready = Completer<void>();
      final navigator = GlobalKey<NavigatorState>();
      final release = Completer<void>();
      handler = IntentHandlerService(
        sharingIntent: sharing,
        imageNotes: _RecordingImages(block: release.future),
        importIosImages: () async => 0,
        openImageNote: (_) {},
      );
      handler.init(ready: ready.future);
      // testWidgets verifies global overrides before the outer tearDown runs.
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          localizationsDelegates: betterKeepLocalizationDelegates,
          supportedLocales: betterKeepSupportedLocales,
          builder: (_, child) =>
              ImageShareProgress(busy: handler.importingImages, child: child!),
          home: const Scaffold(body: Text('Home')),
        ),
      );
      final pendingImport = handler.handleSharedFiles([
        SharedMediaFile(path: '/queued.jpg', type: SharedMediaType.image),
      ]);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      ready.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('Processing image...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(navigator.currentState!.canPop(), isFalse);
      release.complete();
      await tester.pump();
      await pendingImport;
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Home'), findsOneWidget);
      expect(navigator.currentState!.canPop(), isFalse);
    },
  );

  testWidgets('startup completes after a frame', (tester) async {
    debugDefaultTargetPlatformOverride = null;
    final ready = Completer<void>();
    completeImageIntentStartup(ready);
    expect(ready.isCompleted, isFalse);
    await tester.pump();
    expect(ready.isCompleted, isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('startup watchdog completes before a delayed frame', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = null;
    final ready = Completer<void>();
    var completedBeforeFrame = false;
    // Registered first: this runs before the helper's post-frame completion.
    tester.binding.addPostFrameCallback((_) {
      completedBeforeFrame = ready.isCompleted;
    });
    completeImageIntentStartup(ready);
    await tester.pump(const Duration(seconds: 5));
    expect(completedBeforeFrame, isTrue);
  });

  test(
    'a new startup owner releases shares waiting on abandoned readiness',
    () async {
      final oldReady = Completer<void>();
      final newReady = Completer<void>();
      final images = _RecordingImages();
      handler = IntentHandlerService(
        sharingIntent: sharing,
        imageNotes: images,
        importIosImages: () async => 0,
        openImageNote: (_) {},
      );
      handler.init(ready: oldReady.future);
      final pending = handler.handleSharedFiles([
        SharedMediaFile(path: '/remounted.jpg', type: SharedMediaType.image),
      ]);
      await Future<void>.delayed(Duration.zero);
      handler.init(ready: newReady.future);
      await Future<void>.delayed(Duration.zero);
      expect(images.paths, isEmpty);
      expect(sharing.subscriptions, 1);
      newReady.complete();
      await pending;
      expect(images.paths, ['/remounted.jpg']);
      oldReady.complete();
    },
  );

  test('empty initial and resume checks never show progress', () async {
    handler = IntentHandlerService(
      sharingIntent: sharing,
      importIosImages: () async => 0,
    );
    final busy = <bool>[];
    handler.importingImages.addListener(
      () => busy.add(handler.importingImages.value),
    );
    handler.init();
    await handler.checkPendingIntents();
    await handler.checkPendingIntents();
    expect(busy, isEmpty);
  });

  test('resume before readiness does not read either inbox', () async {
    var reads = 0;
    handler = IntentHandlerService(
      sharingIntent: sharing,
      importIosImages: () async {
        reads++;
        return 0;
      },
    );
    await handler.checkPendingIntents();
    expect(reads, 0);
    expect(sharing.reads, 0);
    handler.init();
    await handler.checkPendingIntents();
    expect(reads, greaterThan(0));
    expect(sharing.reads, greaterThan(0));
  });

  test(
    'a warm share during startup is buffered until services are ready',
    () async {
      final ready = Completer<void>();
      final stream = StreamController<List<SharedMediaFile>>.broadcast(
        sync: true,
      );
      final images = _RecordingImages();
      sharing = _SharingIntent(stream: stream.stream);
      var inboxReads = 0;
      handler = IntentHandlerService(
        sharingIntent: sharing,
        imageNotes: images,
        importIosImages: () async => ++inboxReads,
      );
      handler.init(ready: ready.future);
      stream.add([
        SharedMediaFile(path: '/startup.jpg', type: SharedMediaType.image),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(handler.importingImages.value, isFalse);
      expect(images.paths, isEmpty);
      expect(inboxReads, 0);
      expect(sharing.reads, 0);
      ready.complete();
      await images.imported.future;
      await handler.checkPendingIntents();
      expect(handler.importingImages.value, isFalse);
      expect(images.paths, ['/startup.jpg']);
      expect(inboxReads, greaterThan(0));
      await stream.close();
    },
  );

  test(
    'an unavailable iOS inbox does not block normal intents or repeat',
    () async {
      var reads = 0;
      handler = IntentHandlerService(
        sharingIntent: sharing,
        importIosImages: () async {
          reads++;
          throw PlatformException(code: 'image_share_unavailable');
        },
      );
      handler.init();
      await handler.checkPendingIntents();
      await handler.checkPendingIntents();
      expect(reads, 1);
      expect(sharing.reads, greaterThanOrEqualTo(2));
    },
  );

  test(
    'transient inbox error allows normal intents and a later retry',
    () async {
      var reads = 0;
      handler = IntentHandlerService(
        sharingIntent: sharing,
        importIosImages: () async {
          reads++;
          if (reads == 1) throw StateError('Locked or temporarily unavailable');
          return 0;
        },
      );
      handler.init();
      await handler.checkPendingIntents();
      expect(reads, 2);
      expect(sharing.reads, 2);
    },
  );

  test('a request at every drain completion boundary is processed', () async {
    for (var depth = 0; depth < 8; depth++) {
      sharing = _SharingIntent();
      Future<void>? requested;
      void requestAfter(int remaining) {
        if (remaining == 0) {
          requested = handler.checkPendingIntents();
        } else {
          scheduleMicrotask(() => requestAfter(remaining - 1));
        }
      }

      sharing.onRead = () {
        if (sharing.reads == 1) requestAfter(depth);
      };
      handler = IntentHandlerService(
        sharingIntent: sharing,
        importIosImages: () async => 0,
      );
      handler.init();
      await Future<void>.delayed(Duration.zero);
      await requested;
      expect(sharing.reads, 2, reason: 'completion microtask depth $depth');
      handler.dispose();
    }
  });

  test('an event-queue request after a drain is processed', () async {
    final finished = Completer<void>();
    sharing.onRead = () {
      if (sharing.reads != 1) return;
      Timer.run(() async {
        try {
          await handler.checkPendingIntents();
          finished.complete();
        } catch (error, stack) {
          finished.completeError(error, stack);
        }
      });
    };
    handler = IntentHandlerService(
      sharingIntent: sharing,
      importIosImages: () async => 0,
    );
    handler.init();
    await finished.future;
    expect(sharing.reads, 2);
  });

  test(
    'a share arriving during import is drained without parallel imports',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var reads = 0;
      var active = 0;
      var maxActive = 0;
      handler = IntentHandlerService(
        sharingIntent: sharing,
        importIosImages: () async {
          reads++;
          active++;
          if (active > maxActive) maxActive = active;
          if (reads == 1) {
            started.complete();
            await release.future;
          }
          active--;
          return 0;
        },
      );
      handler.init();
      await started.future;
      final first = handler.checkPendingIntents();
      final second = handler.checkPendingIntents();
      expect(reads, 1);
      release.complete();
      await Future.wait([first, second]);
      expect(reads, 2);
      expect(sharing.reads, 2);
      expect(maxActive, 1);
    },
  );
}

class _SharingIntent extends ReceiveSharingIntent {
  _SharingIntent({this.stream = const Stream.empty()});
  final Stream<List<SharedMediaFile>> stream;
  int reads = 0;
  int subscriptions = 0;
  void Function()? onRead;
  @override
  Stream<List<SharedMediaFile>> getMediaStream() {
    subscriptions++;
    return stream;
  }

  @override
  Future<List<SharedMediaFile>> getInitialMedia() async {
    reads++;
    onRead?.call();
    return [];
  }
}

class _RecordingImages extends SharedImageNoteService {
  _RecordingImages({this.block});
  final Future<void>? block;
  final paths = <String>[];
  final imported = Completer<void>();

  @override
  Future<Note> create(List<SharedMediaFile> images, {String? shareId}) async {
    paths.addAll(images.map((image) => image.path));
    imported.complete();
    await block;
    return Note();
  }
}
