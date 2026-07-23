import 'dart:async';
import 'dart:io';

import 'package:better_keep/l10n/app_localizations.dart';
import 'package:better_keep/services/assistant_note_capture_service.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef AssistantNoteConfirmation =
    Future<bool> Function(AssistantNoteCaptureRequest request);

class AssistantNotesPlatformBridge {
  AssistantNotesPlatformBridge({
    AssistantNoteCaptureService? service,
    AssistantNoteConfirmation? confirm,
    MethodChannel? channel,
  }) : _service = service ?? AssistantNoteCaptureService.instance,
       _confirm = confirm ?? _showConfirmation,
       _channel =
           channel ??
           const MethodChannel('io.foxbiz.better_keep/assistant_notes');

  static final AssistantNotesPlatformBridge instance =
      AssistantNotesPlatformBridge();

  final AssistantNoteCaptureService _service;
  final AssistantNoteConfirmation _confirm;
  final MethodChannel _channel;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized || kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    await _channel.invokeMethod<void>('ready');
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method != 'createNote') {
      throw MissingPluginException('Unsupported assistant notes method');
    }
    if (call.arguments is! Map) {
      return const AssistantNoteCaptureResult.failed().toMap();
    }
    return handleRequest(Map<Object?, Object?>.from(call.arguments as Map));
  }

  @visibleForTesting
  Future<Map<String, Object>> handleRequest(
    Map<Object?, Object?> arguments,
  ) async {
    final request = AssistantNoteCaptureRequest.fromMap(arguments);
    if (!request.isValid) {
      return const AssistantNoteCaptureResult.failed().toMap();
    }
    if (!_service.isAvailable) {
      return const AssistantNoteCaptureResult.unavailable().toMap();
    }

    if (_requiresConfirmation(request.source)) {
      final confirmed = await _confirm(request);
      if (!confirmed) {
        return const AssistantNoteCaptureResult.cancelled().toMap();
      }
    }

    final result = await _service.capture(request);
    if (result.status == AssistantNoteCaptureStatus.saved) {
      _showSavedMessage();
    }
    return result.toMap();
  }

  static bool _requiresConfirmation(String source) =>
      source == 'androidCreateNote' || source == 'googleAssistant';

  static Future<bool> _showConfirmation(
    AssistantNoteCaptureRequest request,
  ) async {
    final context = await _waitForContext();
    if (context == null || !context.mounted) return false;
    final l10n = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.saveVoiceNoteTitle),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (request.normalizedTitle != null) ...[
                    Text(
                      l10n.voiceNoteTitleLabel,
                      style: Theme.of(dialogContext).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(request.normalizedTitle!),
                    const SizedBox(height: 16),
                  ],
                  if (request.normalizedText != null) ...[
                    Text(
                      l10n.voiceNoteContentLabel,
                      style: Theme.of(dialogContext).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 4),
                    SelectableText(request.normalizedText!),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.save),
              ),
            ],
          ),
        ) ??
        false;
  }

  static Future<BuildContext?> _waitForContext() async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final context = AppState.navigatorKey.currentContext;
      if (context != null) return context;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  static void _showSavedMessage() {
    final context = AppState.navigatorKey.currentContext;
    if (context == null) return;
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    AppState.scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(l10n.voiceNoteSaved)),
    );
  }
}
