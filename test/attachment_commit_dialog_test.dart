import 'dart:async';

import 'package:better_keep/dialogs/attachment_commit_dialog.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/services/new_attachment_transaction_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('failure offers retry and reports success only after commit', (
    tester,
  ) async {
    var attempts = 0;
    bool? result;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await commitAttachmentWithRetry(
                  context: context,
                  sourcePath: '/docs/retry.wav',
                  commit: () async {
                    attempts++;
                    if (attempts == 1) {
                      throw StateError('injected failure');
                    }
                  },
                );
              },
              child: const Text('Attach'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(result, isNull);
    expect(find.text('Couldn’t add attachment'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(result, isTrue);
    expect(find.text('Couldn’t add attachment'), findsNothing);
  });

  testWidgets('duplicate commit for one source is rejected while pending', (
    tester,
  ) async {
    final release = Completer<void>();
    bool? firstResult;
    bool? secondResult;
    var discarded = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                FilledButton(
                  onPressed: () async {
                    firstResult = await commitAttachmentWithRetry(
                      context: context,
                      sourcePath: '/docs/pending.jpg',
                      commit: () => release.future,
                      discardSource: (_) async {
                        discarded++;
                      },
                    );
                  },
                  child: const Text('First'),
                ),
                FilledButton(
                  onPressed: () async {
                    secondResult = await commitAttachmentWithRetry(
                      context: context,
                      sourcePath: '/docs/pending.jpg',
                      commit: () async {},
                      discardSource: (_) async {
                        discarded++;
                      },
                    );
                  },
                  child: const Text('Second'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('First'));
    await tester.pump();
    await tester.tap(find.text('Second'));
    await tester.pump();

    expect(secondResult, isFalse);
    expect(firstResult, isNull);
    release.complete();
    await tester.pumpAndSettle();
    expect(firstResult, isTrue);
    expect(discarded, 0);
  });

  testWidgets('unmounting after commit failure discards the source once', (
    tester,
  ) async {
    final commitResult = Completer<void>();
    bool? result;
    final discardedPaths = <String>[];
    final sourceLease = UncommittedAttachmentSourceLease(
      sourcePath: '/docs/unmounted.wav',
      cleanupSource: (sourcePath) async {
        discardedPaths.add(sourcePath);
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await commitAttachmentWithRetry(
                context: context,
                sourcePath: '/docs/unmounted.wav',
                commit: () => commitResult.future,
                sourceLease: sourceLease,
              );
            },
            child: const Text('Attach'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Attach'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    commitResult.completeError(StateError('injected failure'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
    expect(discardedPaths, ['/docs/unmounted.wav']);
    await sourceLease.releaseByCaller();
    expect(discardedPaths, ['/docs/unmounted.wav']);
    expect(find.text('Couldn’t add attachment'), findsNothing);
  });

  testWidgets('failure-prompt callback errors still discard the source', (
    tester,
  ) async {
    bool? result;
    var discarded = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await commitAttachmentWithRetry(
                context: context,
                sourcePath: '/docs/prompt-error.jpg',
                commit: () async => throw StateError('commit failed'),
                beforeFailurePrompt: () async =>
                    throw StateError('prompt setup failed'),
                discardSource: (_) async {
                  discarded++;
                },
              );
            },
            child: const Text('Attach'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
    expect(discarded, 1);
    expect(find.text('Couldn’t add attachment'), findsNothing);
  });

  testWidgets('retry setup failure discards instead of escaping', (
    tester,
  ) async {
    bool? result;
    var discarded = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await commitAttachmentWithRetry(
                context: context,
                sourcePath: '/docs/retry-setup.wav',
                commit: () async => throw StateError('commit failed'),
                beforeRetry: () async => throw StateError('retry setup failed'),
                discardSource: (_) async {
                  discarded++;
                },
              );
            },
            child: const Text('Attach'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Attach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
    expect(discarded, 1);
    expect(find.text('Couldn’t add attachment'), findsNothing);
  });
}
