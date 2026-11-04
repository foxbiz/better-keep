import 'package:flutter/foundation.dart';

/// Only the opt-in web build changes local storage. Native/stable names stay intact.
const isBetaWebBuild = kIsWeb && bool.fromEnvironment('WEB_BETA');
const webStoragePrefix = isBetaWebBuild ? 'beta_' : '';
const webFirebaseAppName = isBetaWebBuild ? 'better-keep-beta' : '[DEFAULT]';
// All beta releases share one worker for their shared database. Changing this
// runtime requires an explicit storage/worker compatibility review.
const betaWorkerBase = '/app/beta-runtime/v1/';
