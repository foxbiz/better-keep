import 'package:google_sign_in/google_sign_in.dart';

Future<void>? _initialization;

/// Login and storage authorization share initialization, never Firebase tokens.
Future<void> initializeNativeGoogleSignIn() =>
    _initialization ??= GoogleSignIn.instance.initialize();
