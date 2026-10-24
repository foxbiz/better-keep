import 'package:better_keep/services/local_storage_recovery.dart';
import 'package:better_keep/services/storage_health_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/l10n_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class StorageWarning extends StatelessWidget {
  const StorageWarning({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: StorageHealthService.instance,
    builder: (context, _) {
      if (!StorageHealthService.instance.isLow) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final dark = theme.brightness == Brightness.dark;
      final background = dark
          ? const Color(0xFF382D18)
          : const Color(0xFFFFF4D6);
      final foreground = dark
          ? const Color(0xFFFFE5AA)
          : const Color(0xFF573B00);
      final accent = dark ? const Color(0xFFFFC857) : const Color(0xFF936300);
      return Material(
        color: theme.colorScheme.surface,
        child: SafeArea(
          bottom: false,
          child: Semantics(
            liveRegion: true,
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 800),
                margin: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: accent.withValues(alpha: 0.45)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.storage_rounded,
                        color: accent,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            context.l10n.storageLowTitle,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: foreground,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            kIsWeb
                                ? context.l10n.browserStorageLow
                                : context.l10n.deviceStorageLow,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: foreground,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Only the login screen shows the retained explanation for automatic logout.
class StorageLossNotice extends StatelessWidget {
  const StorageLossNotice({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String?>(
    valueListenable: LocalStorageRecovery.notice,
    builder: (context, reason, _) {
      if (reason == null) return const SizedBox.shrink();
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.storageLoginAgain,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  reason == 'pressure'
                      ? context.l10n.storageClearedAfterPressure
                      : context.l10n.storageCleared,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () async =>
                        LocalStorageRecovery(await AppState.prefs)
                            .dismissNotice(),
                    child: Text(context.l10n.dismiss),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
