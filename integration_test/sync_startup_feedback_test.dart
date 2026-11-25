import 'package:integration_test/integration_test.dart';
import 'package:better_keep/services/firebase_backend.dart';

import '../test/support/sync_startup_feedback_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (FirebaseBackend.isConfigured) {
    throw StateError(
      'Run startup fixtures without a configured Firebase session',
    );
  }
  syncStartupFeedbackCases();
}
