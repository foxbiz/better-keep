import 'package:flutter_test/flutter_test.dart';

import 'support/sync_startup_feedback_cases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  syncStartupFeedbackCases();
}
