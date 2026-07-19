import 'dart:async';

import 'package:better_keep/components/note_audio_player.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/models/note_recording.dart';
import 'package:better_keep/services/audio_playback_source_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('source failure shows a retry control without native playback', (
    tester,
  ) async {
    var resolutions = 0;

    await tester.pumpWidget(
      _app(
        NoteAudioPlayer(
          recording: NoteRecording(
            src: '/protected/audio.wav',
            title: 'Recording',
          ),
          noteLocked: true,
          sourceResolver: (source, {required protectedSource}) async {
            resolutions++;
            expect(protectedSource, isTrue);
            throw const AudioPlaybackSourceException(
              AudioPlaybackSourceError.passwordProtected,
              'still protected',
            );
          },
          onDelete: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(resolutions, 1);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();
    expect(resolutions, 2);
  });

  testWidgets('a stale resolved lease is released after the source changes', (
    tester,
  ) async {
    final firstResolution = Completer<AudioPlaybackSourceLease>();
    var released = 0;

    Future<AudioPlaybackSourceLease> resolver(
      String source, {
      required bool protectedSource,
    }) {
      if (source == '/audio/first.wav') return firstResolution.future;
      throw const AudioPlaybackSourceException(
        AudioPlaybackSourceError.missing,
        'replacement is unavailable',
      );
    }

    await tester.pumpWidget(
      _app(
        NoteAudioPlayer(
          recording: NoteRecording(src: '/audio/first.wav', title: 'Recording'),
          noteLocked: true,
          sourceResolver: resolver,
          onDelete: () {},
        ),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      _app(
        NoteAudioPlayer(
          recording: NoteRecording(
            src: '/audio/second.wav',
            title: 'Recording',
          ),
          noteLocked: true,
          sourceResolver: resolver,
          onDelete: () {},
        ),
      ),
    );
    firstResolution.complete(
      AudioPlaybackSourceLease.deviceFile(
        '/cache/audio_playback/first.wav',
        isTemporary: true,
        release: () async => released++,
      ),
    );
    await tester.pumpAndSettle();

    expect(released, 1);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  testWidgets('rapid play requests share the pending source preparation', (
    tester,
  ) async {
    final resolution = Completer<AudioPlaybackSourceLease>();
    var resolutions = 0;

    await tester.pumpWidget(
      _app(
        NoteAudioPlayer(
          recording: NoteRecording(src: '/audio/pending.wav'),
          sourceResolver: (source, {required protectedSource}) {
            resolutions++;
            return resolution.future;
          },
          onDelete: () {},
        ),
      ),
    );
    await tester.pump();

    final state = tester.state<NoteAudioPlayerState>(
      find.byType(NoteAudioPlayer),
    );
    state.play();
    state.play();
    expect(resolutions, 1);

    resolution.completeError(
      const AudioPlaybackSourceException(
        AudioPlaybackSourceError.missing,
        'pending source disappeared',
      ),
    );
    await tester.pumpAndSettle();

    expect(resolutions, 1);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  testWidgets('disposal during preparation releases the eventual lease', (
    tester,
  ) async {
    final resolution = Completer<AudioPlaybackSourceLease>();
    var released = 0;

    await tester.pumpWidget(
      _app(
        NoteAudioPlayer(
          recording: NoteRecording(src: '/audio/pending.wav'),
          sourceResolver: (source, {required protectedSource}) =>
              resolution.future,
          onDelete: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(_app(const SizedBox.shrink()));

    resolution.complete(
      AudioPlaybackSourceLease.deviceFile(
        '/cache/audio_playback/pending.wav',
        isTemporary: true,
        release: () async => released++,
      ),
    );
    await tester.pumpAndSettle();

    expect(released, 1);
  });

  testWidgets('authenticated-session changes reinitialize the same source', (
    tester,
  ) async {
    var resolutions = 0;

    Future<AudioPlaybackSourceLease> resolver(
      String source, {
      required bool protectedSource,
    }) async {
      resolutions++;
      throw const AudioPlaybackSourceException(
        AudioPlaybackSourceError.passwordProtected,
        'protected for test',
      );
    }

    await tester.pumpWidget(
      _app(
        NoteAudioPlayer(
          recording: NoteRecording(src: '/audio/protected.wav'),
          noteLocked: true,
          noteSessionUnlocked: false,
          sourceResolver: resolver,
          onDelete: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(resolutions, 1);

    await tester.pumpWidget(
      _app(
        NoteAudioPlayer(
          recording: NoteRecording(src: '/audio/protected.wav'),
          noteLocked: true,
          noteSessionUnlocked: true,
          sourceResolver: resolver,
          onDelete: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(resolutions, 2);
  });
}

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);
