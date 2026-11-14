import 'package:flutter/material.dart';

import '../../services/external_sync/storage_usage.dart';
import '../../utils/l10n_helper.dart';

/// Refresh on connection/sync changes, not on every settings rebuild.
class StorageUsageText extends StatefulWidget {
  const StorageUsageText({
    super.key,
    required this.load,
    required this.revision,
  });
  final Future<StorageUsage?> Function() load;
  final Object revision;
  @override
  State<StorageUsageText> createState() => _StorageUsageTextState();
}

class _StorageUsageTextState extends State<StorageUsageText> {
  late Future<StorageUsage?> _usage;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(StorageUsageText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _reload();
  }

  void _reload() {
    _usage = Future<StorageUsage?>.sync(widget.load)
        .catchError((Object _) => null);
  }

  String _bytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    var value = bytes.toDouble(), index = 0;
    while (value >= 1000 && index < units.length - 1) {
      value /= 1000;
      index++;
    }
    return '${value.toStringAsFixed(index == 0 || value == value.roundToDouble() ? 0 : 1)} ${units[index]}';
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<StorageUsage?>(
    future: _usage,
    builder: (context, snapshot) {
      final usage = snapshot.connectionState == ConnectionState.done
          ? snapshot.data
          : null;
      return Text(
        snapshot.connectionState != ConnectionState.done
            ? context.l10n.externalSyncCapacityLoading
            : usage == null
            ? context.l10n.externalSyncCapacityUnavailable
            : context.l10n.externalSyncCapacity(
                _bytes(usage.usedBytes),
                _bytes(usage.totalBytes),
              ),
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    },
  );
}
