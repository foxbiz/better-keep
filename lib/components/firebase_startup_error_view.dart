import 'package:flutter/material.dart';

class FirebaseStartupErrorView extends StatelessWidget {
  const FirebaseStartupErrorView({
    super.key,
    required this.error,
    this.onRetry,
  });

  final String error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final retry = onRetry;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 64,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Firebase startup failed',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(error, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    Text(
                      retry == null
                          ? 'Restart the app before changing Firebase '
                                'environments.'
                          : 'Check your connection, then retry. Your local data '
                                'has not been changed.',
                      textAlign: TextAlign.center,
                    ),
                    if (retry != null) ...[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
