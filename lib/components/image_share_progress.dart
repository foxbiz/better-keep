import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Keeps the existing route visible while shared images are copied and saved.
class ImageShareProgress extends StatelessWidget {
  const ImageShareProgress({
    super.key,
    required this.child,
    required this.busy,
  });

  final Widget child;
  final ValueListenable<bool> busy;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: busy,
    builder: (context, busy, _) => Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (busy) ...[
          const ModalBarrier(dismissible: false, color: Colors.black26),
          Center(
            child: Semantics(
              liveRegion: true,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(context.l10n.processingImage),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}
