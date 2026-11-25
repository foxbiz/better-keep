import 'package:flutter/material.dart';

import '../services/firebase_sync_preference.dart';
import '../ui/custom_icons.dart';
import '../utils/l10n_helper.dart';

const syncProviderOptions = {
  'google_drive': (name: 'Google Drive', icon: CustomIcons.googledrive),
  'dropbox': (name: 'Dropbox', icon: CustomIcons.dropbox),
  'webdav': (name: 'WebDAV', icon: Icons.dns_outlined),
  'nextcloud': (name: 'Nextcloud', icon: CustomIcons.nextcloud),
};

String syncProviderDisplayName(
  BuildContext context,
  FirebaseSyncPreference preference,
) =>
    syncProviderOptions[preference.selectedProvider]?.name ??
    switch (preference.selectedProvider) {
      'firebase' => context.l10n.externalSyncCloud,
      'none' => context.l10n.externalSyncOff,
      _ =>
        preference.failed
            ? context.l10n.externalSyncNeedsAttention
            : preference.accountId == null
            ? context.l10n.externalSyncState('notConnected')
            : context.l10n.loading,
    };

/// Shared account/settings entry; follows provider changes across devices.
class SyncProviderTile extends StatelessWidget {
  const SyncProviderTile({super.key, required this.onTap, this.preference});
  final VoidCallback onTap;
  final FirebaseSyncPreference? preference;

  @override
  Widget build(BuildContext context) {
    final selection = preference ?? FirebaseSyncPreference.instance;
    return ListenableBuilder(
      listenable: selection,
      builder: (context, _) {
        final provider = selection.selectedProvider;
        final option = syncProviderOptions[provider];
        return ListTile(
          leading: Icon(
            option?.icon ??
                (provider == 'none'
                    ? Icons.cloud_off_outlined
                    : Icons.cloud_outlined),
          ),
          title: Text(context.l10n.externalSyncTitle),
          subtitle: Text(syncProviderDisplayName(context, selection)),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        );
      },
    );
  }
}
