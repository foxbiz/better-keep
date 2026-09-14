import 'dart:async';

import 'package:better_keep/dialogs/loading_dialog.dart';
import 'package:better_keep/l10n/app_localizations.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'failed loading operation preserves error and closes only its dialog',
    (tester) async {
      final operation = Completer<void>();
      LoadingDialogResult<void>? result;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showLoadingDialog<void>(
                    context: context,
                    config: const LoadingDialogConfig(
                      message: 'Sending code',
                      timeoutMessage: 'Timed out',
                    ),
                    operation: () => operation.future,
                  );
                },
                child: const Text('Link account'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Link account'));
      await tester.pump();
      final error = FirebaseFunctionsException(
        code: 'resource-exhausted',
        message: 'Please wait 10 seconds before requesting a new code.',
      );
      operation.completeError(error);
      await tester.pumpAndSettle();
      expect(result?.success, false);
      expect(result?.error, same(error));
      expect(result?.cancelled, false);
      expect(result?.timedOut, false);
      expect(find.text('Sending code'), findsNothing);
      expect(find.text('Link account'), findsOneWidget);
    },
  );
}
