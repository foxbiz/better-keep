import 'dart:convert';

import 'package:flutter/foundation.dart' show compute, kDebugMode;
import 'package:better_keep/models/note_sync_track.dart';
import 'package:share_plus/share_plus.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/note_sync_service.dart';
import 'package:better_keep/services/remote_sync_cache_service.dart';
import 'package:better_keep/state.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:better_keep/utils/utils.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;

class NerdStatsPage extends StatefulWidget {
  const NerdStatsPage({super.key});

  @override
  State<NerdStatsPage> createState() => _NerdStatsPageState();
}

class _NerdStatsPageState extends State<NerdStatsPage> {
  Map<String, dynamic> _stats = {};
  List<NoteSyncTrack> _pendingItems = [];
  bool _loading = true;
  bool _isRefreshing = false;

  // Web-specific state
  String _opfsStatus = '';
  List<Map<String, dynamic>> _opfsFiles = [];
  bool _loadingOpfs = false;
  Map<String, dynamic>? _opfsTestResult;

  // Sync cache state
  Map<String, dynamic>? _cacheDebugInfo;
  bool _loadingCache = false;

  // Database viewer state
  List<String> _dbTables = [];
  String? _selectedTable;
  List<Map<String, dynamic>> _tableRows = [];
  List<String> _tableColumns = [];
  Map<String, double> _columnWidths = {};
  bool _loadingDb = false;
  int _tableRowCount = 0;
  int _dbViewLimit = 50;
  int _dbViewOffset = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    NoteSyncService().isSyncing.addListener(_onSyncStatusChange);
  }

  @override
  void dispose() {
    NoteSyncService().isSyncing.removeListener(_onSyncStatusChange);
    super.dispose();
  }

  void _onSyncStatusChange() {
    // Don't refresh while already refreshing
    if (_isRefreshing) return;
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    if (_isRefreshing) return;

    _isRefreshing = true;
    setState(() => _loading = true);

    try {
      // Run all async operations in parallel for faster loading
      final results =
          await Future.wait([
            NoteSyncTrack.count(status: SyncStatus.synced),
            NoteSyncTrack.count(status: SyncStatus.failed),
            NoteSyncTrack.count(),
            NoteSyncTrack.get(pending: true),
            _getDbSize(),
          ]).timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              // Return default values on timeout
              return [0, 0, 0, <NoteSyncTrack>[], 0];
            },
          );

      if (mounted) {
        setState(() {
          _stats = {
            'Synced Notes': results[0] as int,
            'Pending Notes': (results[3] as List).length,
            'Failed Notes': results[1] as int,
            'SyncTrack Items': results[2] as int,
            'DB Size': '${((results[4] as int) / 1024).toStringAsFixed(2)} KB',
            'Is Syncing': NoteSyncService().isSyncing.value,
            'Cache Has Pending': RemoteSyncCacheService().hasPendingSyncs,
            'Cache Initialized': RemoteSyncCacheService().metadata != null,
          };
          _pendingItems = results[3] as List<NoteSyncTrack>;
          _loading = false;
          _isRefreshing = false;
        });
      } else {
        _isRefreshing = false;
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _stats = {'Error': e.toString()};
          _loading = false;
          _isRefreshing = false;
        });
      } else {
        _isRefreshing = false;
      }
    }
  }

  Future<int> _getDbSize() async {
    // Skip on web as getDatabasesPath can be slow/problematic
    if (kIsWeb) return 0;

    try {
      String dbPath = await getDatabasesPath();
      dbPath = path.join(dbPath, 'better_keep.db');
      final fs = await fileSystem();
      return (await fs.length(dbPath)) ?? 0;
    } catch (e) {
      return 0;
    }
  }

  Future<void> _loadOpfsInfo() async {
    if (!kIsWeb || _loadingOpfs) return;
    setState(() => _loadingOpfs = true);

    try {
      final fs = await fileSystem();
      // Use dynamic access for web-specific properties
      final dynamic webFs = fs;
      _opfsStatus =
          'Backend: ${webFs.backendType}\\nOPFS Supported: ${webFs.opfsSupported}';
      _opfsFiles =
          await (webFs.listRecursive('/') as Future<List<Map<String, dynamic>>>)
              .timeout(
                const Duration(seconds: 10),
                onTimeout: () => [
                  {
                    'path': 'Timeout',
                    'type': 'error',
                    'message': 'Loading took too long',
                  },
                ],
              );
    } catch (e) {
      _opfsStatus = 'Error: $e';
      _opfsFiles = [];
    }

    if (mounted) {
      setState(() => _loadingOpfs = false);
    }
  }

  Future<void> _loadCacheDebugInfo() async {
    if (_loadingCache) return;
    setState(() => _loadingCache = true);

    try {
      _cacheDebugInfo = await RemoteSyncCacheService().getDebugInfo().timeout(
        const Duration(seconds: 5),
        onTimeout: () => {'error': 'Timeout loading cache info'},
      );
    } catch (e) {
      _cacheDebugInfo = {'error': e.toString()};
    }

    if (mounted) {
      setState(() => _loadingCache = false);
    }
  }

  Future<void> _loadDbTables() async {
    if (_loadingDb) return;
    setState(() => _loadingDb = true);

    try {
      final tables = await AppState.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%' ORDER BY name",
      );
      _dbTables = tables.map((t) => t['name'] as String).toList();
    } catch (e) {
      _dbTables = [];
    }

    if (mounted) {
      setState(() => _loadingDb = false);
    }
  }

  Future<void> _loadTableData(String tableName) async {
    setState(() {
      _loadingDb = true;
      _selectedTable = tableName;
      _dbViewOffset = 0;
    });

    try {
      // Get row count
      final countResult = await AppState.db.rawQuery(
        'SELECT COUNT(*) as count FROM "$tableName"',
      );
      _tableRowCount = countResult.first['count'] as int? ?? 0;

      // Get column info
      final columnsResult = await AppState.db.rawQuery(
        'PRAGMA table_info("$tableName")',
      );
      _tableColumns = columnsResult.map((c) => c['name'] as String).toList();

      // Get rows with pagination
      _tableRows = await AppState.db.rawQuery(
        'SELECT * FROM "$tableName" LIMIT $_dbViewLimit OFFSET $_dbViewOffset',
      );

      // Calculate column widths based on content
      _calculateColumnWidths();
    } catch (e) {
      _tableRows = [];
      _tableColumns = [];
      _tableRowCount = 0;
      _columnWidths = {};
    }

    if (mounted) {
      setState(() => _loadingDb = false);
    }
  }

  void _calculateColumnWidths() {
    _columnWidths = {};
    const double minWidth = 60;
    const double maxWidth = 250;
    const double charWidth =
        7.0; // Approximate width per character for monospace
    const double headerCharWidth = 8.0; // Slightly wider for bold header
    const double padding = 16; // Horizontal padding

    for (final col in _tableColumns) {
      // Start with header width
      double maxContentWidth = col.length * headerCharWidth + padding;

      // Check all rows for this column
      for (final row in _tableRows) {
        final value = _formatCellValue(row[col]);
        final contentWidth = value.length * charWidth + padding;
        if (contentWidth > maxContentWidth) {
          maxContentWidth = contentWidth;
        }
      }

      // Clamp to min/max
      _columnWidths[col] = maxContentWidth.clamp(minWidth, maxWidth);
    }
  }

  Future<void> _loadMoreRows() async {
    if (_selectedTable == null || _loadingDb) return;
    setState(() => _loadingDb = true);

    try {
      _dbViewOffset += _dbViewLimit;
      final moreRows = await AppState.db.rawQuery(
        'SELECT * FROM "$_selectedTable" LIMIT $_dbViewLimit OFFSET $_dbViewOffset',
      );
      _tableRows = [..._tableRows, ...moreRows];
    } catch (e) {
      // ignore
    }

    if (mounted) {
      setState(() => _loadingDb = false);
    }
  }

  Future<void> _deleteRow(String tableName, Map<String, dynamic> row) async {
    // Find primary key or use rowid
    String whereClause;
    List<Object?> whereArgs;

    if (row.containsKey('id') && row['id'] != null) {
      whereClause = 'id = ?';
      whereArgs = [row['id']];
    } else if (row.containsKey('rowid') && row['rowid'] != null) {
      whereClause = 'rowid = ?';
      whereArgs = [row['rowid']];
    } else {
      // Build where clause from all columns
      final entries = row.entries.where((e) => e.value != null).toList();
      whereClause = entries.map((e) => '"${e.key}" = ?').join(' AND ');
      whereArgs = entries.map((e) => e.value).toList();
    }

    await AppState.db.delete(
      tableName,
      where: whereClause,
      whereArgs: whereArgs,
    );
    await _loadTableData(tableName);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Nerd Stats"),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _buildStatCard(),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: ValueListenableBuilder<String>(
                    valueListenable: NoteSyncService().statusMessage,
                    builder: (context, status, child) {
                      if (status.isEmpty) return const SizedBox.shrink();
                      return Card(
                        color: Colors.blue.withValues(alpha: 0.1),
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Text(
                            "Status: $status",
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    "Pending Sync Items (${_pendingItems.length})",
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ..._pendingItems.map(
                  (item) => ListTile(
                    title: Text(item.action.name.toUpperCase()),
                    subtitle: Text(
                      "Local: ${item.localId}\nRemote: ${item.remoteId ?? 'N/A'}\nStatus: ${item.status}",
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () async {
                        await AppState.db.delete(
                          'sync_track',
                          where: 'id = ?',
                          whereArgs: [item.id],
                        );
                        _refresh();
                      },
                    ),
                  ),
                ),
                const Divider(),
                // OPFS section (Web only)
                if (kIsWeb) ...[_buildOpfsSection(), const Divider()],
                // SQLite Database Viewer (debug only - exposes raw DB access)
                if (kDebugMode) ...[
                  _buildDatabaseViewerSection(),
                  const Divider(),
                ],
                // Sync Cache Debug section
                _buildCacheDebugSection(),
                const Divider(),
                ListTile(
                  title: const Text("View Sync Logs"),
                  subtitle: const Text("Check errors and debugging info"),
                  trailing: const Icon(Icons.description),
                  onTap: () {
                    showPage(context, const LogViewerPage());
                  },
                ),
                ListTile(
                  title: const Text("Clear Sync Track"),
                  subtitle: const Text(
                    "Deletes all pending sync items (Dangerous)",
                  ),
                  trailing: const Icon(Icons.delete_forever, color: Colors.red),
                  onTap: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Clear Sync Track?'),
                        content: const Text(
                          'This will delete all pending sync items. '
                          'This action cannot be undone and may cause sync issues.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                            child: const Text('Delete All'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await AppState.db.delete('sync_track');
                      _refresh();
                    }
                  },
                ),
              ],
            ),
    );
  }

  Widget _buildOpfsSection() {
    return ExpansionTile(
      title: const Text("OPFS / File System"),
      subtitle: Text(_opfsStatus.isEmpty ? 'Tap to load' : _opfsStatus),
      leading: const Icon(Icons.folder_open),
      onExpansionChanged: (expanded) {
        if (expanded && _opfsFiles.isEmpty && !_loadingOpfs) {
          _loadOpfsInfo();
        }
      },
      children: [
        // OPFS Test button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              ElevatedButton.icon(
                onPressed: _runOpfsTest,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Run OPFS Test'),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () {
                  setState(() {
                    _opfsFiles = [];
                    _opfsStatus = '';
                    _opfsTestResult = null;
                  });
                  _loadOpfsInfo();
                },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        // Test results
        if (_opfsTestResult != null)
          Container(
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _opfsTestResult!['error'] != null
                  ? Colors.red.withValues(alpha: 0.1)
                  : Colors.green.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(_opfsTestResult),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        if (_loadingOpfs)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_opfsFiles.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text("No files found or directory empty"),
          )
        else
          ..._opfsFiles.map(
            (file) => ListTile(
              dense: true,
              leading: Icon(
                _getFileIcon(file['type'] as String?),
                size: 20,
                color: file['type'] == 'error' ? Colors.red : null,
              ),
              title: Text(
                file['path'] as String,
                style: const TextStyle(fontSize: 12),
              ),
              subtitle: Text(
                _getFileSubtitle(file),
                style: TextStyle(
                  fontSize: 10,
                  color: file['type'] == 'error' ? Colors.red : null,
                ),
              ),
            ),
          ),
      ],
    );
  }

  IconData _getFileIcon(String? type) {
    switch (type) {
      case 'directory':
        return Icons.folder;
      case 'file':
        return Icons.insert_drive_file;
      case 'error':
        return Icons.error;
      case 'info':
        return Icons.info;
      default:
        return Icons.help_outline;
    }
  }

  String _getFileSubtitle(Map<String, dynamic> file) {
    if (file['message'] != null) return file['message'] as String;
    if (file['size'] != null) return _formatSize(file['size'] as int);
    if (file['count'] != null) return '${file['count']} items';
    return file['type'] ?? 'unknown';
  }

  Future<void> _runOpfsTest() async {
    if (!kIsWeb) {
      setState(() => _opfsTestResult = {'error': 'Only available on web'});
      return;
    }
    setState(() => _opfsTestResult = {'status': 'Running...'});
    try {
      final fs = await fileSystem();
      final result = await fs.testOpfs().timeout(
        const Duration(seconds: 10),
        onTimeout: () => {'error': 'Test timed out after 10 seconds'},
      );
      setState(() => _opfsTestResult = result);
    } catch (e) {
      setState(() => _opfsTestResult = {'error': e.toString()});
    }
  }

  Widget _buildDatabaseViewerSection() {
    return ExpansionTile(
      title: const Text("SQLite Database Viewer"),
      subtitle: Text(
        _dbTables.isEmpty ? 'Tap to load tables' : '${_dbTables.length} tables',
      ),
      leading: const Icon(Icons.table_chart),
      onExpansionChanged: (expanded) {
        if (expanded && _dbTables.isEmpty && !_loadingDb) {
          _loadDbTables();
        }
      },
      children: [
        if (_loadingDb && _dbTables.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_dbTables.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text("No tables found"),
          )
        else ...[
          // Table selector
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _dbTables.map((table) {
                final isSelected = _selectedTable == table;
                return FilterChip(
                  label: Text(table),
                  selected: isSelected,
                  onSelected: (_) => _loadTableData(table),
                );
              }).toList(),
            ),
          ),
          // Table content
          if (_selectedTable != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text(
                    '$_selectedTable: $_tableRowCount rows',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (_loadingDb)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: () => _loadTableData(_selectedTable!),
                    tooltip: 'Refresh',
                  ),
                ],
              ),
            ),
            // Column headers and rows in a single scrollable area
            if (_tableColumns.isNotEmpty)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                constraints: const BoxConstraints(maxHeight: 400),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: _tableColumns.fold<double>(
                      16,
                      (sum, col) => sum + (_columnWidths[col] ?? 100),
                    ),
                    child: Column(
                      children: [
                        // Header row
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(7),
                            ),
                          ),
                          child: Row(
                            children: _tableColumns.map((col) {
                              return SizedBox(
                                width: _columnWidths[col] ?? 100,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: Text(
                                    col,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                        // Data rows
                        Expanded(
                          child: _tableRows.isEmpty && !_loadingDb
                              ? const Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Text("No rows in this table"),
                                  ),
                                )
                              : ListView.builder(
                                  shrinkWrap: true,
                                  itemCount:
                                      _tableRows.length +
                                      (_tableRows.length < _tableRowCount
                                          ? 1
                                          : 0),
                                  itemBuilder: (context, index) {
                                    if (index >= _tableRows.length) {
                                      // Load more button
                                      return Center(
                                        child: TextButton(
                                          onPressed: _loadingDb
                                              ? null
                                              : _loadMoreRows,
                                          child: _loadingDb
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                      ),
                                                )
                                              : Text(
                                                  'Load more (${_tableRows.length}/$_tableRowCount)',
                                                ),
                                        ),
                                      );
                                    }
                                    final row = _tableRows[index];
                                    return InkWell(
                                      onTap: () => _showRowDetail(row),
                                      onLongPress: () => _showRowActions(row),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 4,
                                          horizontal: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border(
                                            bottom: BorderSide(
                                              color: Theme.of(context)
                                                  .dividerColor
                                                  .withValues(alpha: 0.3),
                                            ),
                                          ),
                                        ),
                                        child: Row(
                                          children: _tableColumns.map((col) {
                                            final value = row[col];
                                            return SizedBox(
                                              width: _columnWidths[col] ?? 100,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 4,
                                                    ),
                                                child: Text(
                                                  _formatCellValue(value),
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontFamily: 'monospace',
                                                    color: value == null
                                                        ? Theme.of(
                                                            context,
                                                          ).hintColor
                                                        : null,
                                                  ),
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ],
      ],
    );
  }

  String _formatCellValue(dynamic value) {
    if (value == null) return 'NULL';
    if (value is String && value.length > 50) {
      return '${value.substring(0, 50)}...';
    }
    return value.toString();
  }

  void _showRowDetail(Map<String, dynamic> row) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Row Details - $_selectedTable'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: row.entries.map((e) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.key,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      e.value?.toString() ?? 'NULL',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: e.value == null
                            ? Theme.of(context).hintColor
                            : null,
                      ),
                    ),
                    const Divider(),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showRowActions(Map<String, dynamic> row) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.visibility),
              title: const Text('View Details'),
              onTap: () {
                Navigator.pop(context);
                _showRowDetail(row);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy as JSON'),
              onTap: () async {
                Navigator.pop(context);
                final json = const JsonEncoder.withIndent('  ').convert(row);
                // Use clipboard
                await Share.share(json);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text(
                'Delete Row',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () async {
                Navigator.pop(context);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Delete Row?'),
                    content: const Text(
                      'This will permanently delete this row from the database. '
                      'This action cannot be undone and may cause app issues.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (confirm == true && _selectedTable != null) {
                  await _deleteRow(_selectedTable!, row);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCacheDebugSection() {
    return ExpansionTile(
      title: const Text("Sync Cache Debug"),
      subtitle: Text(_cacheDebugInfo == null ? 'Tap to load' : 'Loaded'),
      leading: const Icon(Icons.storage),
      onExpansionChanged: (expanded) {
        if (expanded && _cacheDebugInfo == null && !_loadingCache) {
          _loadCacheDebugInfo();
        }
      },
      children: [
        if (_loadingCache)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_cacheDebugInfo == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text("Expand to load cache info"),
          )
        else
          Container(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(_cacheDebugInfo),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
      ],
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _buildStatCard() {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: _stats.entries.map((e) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    e.key,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(e.value.toString()),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

/// Parsed log entry with metadata
class _LogEntry {
  final String rawLine;
  final String? date;
  final String? tag;
  final String? name;
  final String? description;
  final bool isError;

  _LogEntry({
    required this.rawLine,
    this.date,
    this.tag,
    this.name,
    this.description,
    this.isError = false,
  });

  /// Parse a log line into a LogEntry
  /// Format: [date] [tag] NAME: description...
  /// Error format: ![date] [tag] NAME: description...
  factory _LogEntry.parse(String line) {
    final isError = line.startsWith('!');
    final cleanLine = isError ? line.substring(1) : line;

    // Match: [date] [tag] NAME: description
    final regex = RegExp(
      r'^\[([^\]]+)\]\s*(?:\[([^\]]+)\])?\s*([^:]+)?:?\s*(.*)$',
    );
    final match = regex.firstMatch(cleanLine);

    if (match != null) {
      return _LogEntry(
        rawLine: line,
        date: match.group(1),
        tag: match.group(2),
        name: match.group(3)?.trim(),
        description: match.group(4),
        isError: isError,
      );
    }

    return _LogEntry(rawLine: line, isError: isError);
  }

  /// Convert to Map for isolate transfer
  Map<String, dynamic> toMap() => {
    'rawLine': rawLine,
    'date': date,
    'tag': tag,
    'name': name,
    'description': description,
    'isError': isError,
  };

  /// Create from Map after isolate transfer
  factory _LogEntry.fromMap(Map<String, dynamic> map) => _LogEntry(
    rawLine: map['rawLine'] as String,
    date: map['date'] as String?,
    tag: map['tag'] as String?,
    name: map['name'] as String?,
    description: map['description'] as String?,
    isError: map['isError'] as bool,
  );
}

/// Result from parsing logs in isolate
class _ParsedLogsResult {
  final List<_LogEntry> entries;
  final Set<String> tags;

  _ParsedLogsResult(this.entries, this.tags);
}

/// Parse logs in a separate isolate
Future<_ParsedLogsResult> _parseLogsInBackground(String logs) async {
  final result = await compute(_parseLogsIsolate, logs);
  final entries = (result['entries'] as List)
      .map((e) => _LogEntry.fromMap(e))
      .toList();
  final tags = Set<String>.from(result['tags'] as List);
  return _ParsedLogsResult(entries, tags);
}

/// Isolate function to parse logs
Map<String, dynamic> _parseLogsIsolate(String logs) {
  final lines = logs.split('\n');
  final entries = <Map<String, dynamic>>[];
  final tags = <String>{};

  // Regex to detect lines that start with a log entry (with or without error prefix)
  // Format: [date] or ![date]
  final logStartRegex = RegExp(r'^!?\[[\d-]+\s[\d:]+\]');

  String? currentRawLine;
  _LogEntry? currentEntry;

  void flushCurrentEntry() {
    if (currentEntry != null && currentRawLine != null) {
      // Re-parse with full multiline content
      final entry = _LogEntry.parse(currentRawLine!);
      entries.add(entry.toMap());
      if (entry.tag != null && entry.tag!.isNotEmpty) {
        tags.add(entry.tag!);
      }
    }
    currentEntry = null;
    currentRawLine = null;
  }

  for (final line in lines) {
    if (line.trim().isEmpty) continue;

    if (logStartRegex.hasMatch(line)) {
      // This is a new log entry, flush the previous one
      flushCurrentEntry();
      currentRawLine = line;
      currentEntry = _LogEntry.parse(line);
    } else if (currentEntry != null) {
      // This is a continuation line (e.g., stack trace)
      currentRawLine = '$currentRawLine\n$line';
    } else {
      // Orphan line without a parent entry, treat as standalone
      final entry = _LogEntry.parse(line);
      entries.add(entry.toMap());
    }
  }

  // Flush the last entry
  flushCurrentEntry();

  return {'entries': entries, 'tags': tags.toList()};
}

class _LogViewerPageState extends State<LogViewerPage> {
  String? _logs;
  List<_LogEntry> _parsedLogs = [];
  List<_LogEntry> _filteredLogs = [];
  Set<String> _availableTags = {};
  String? _selectedTag;
  bool _loading = true;
  bool _isSearching = false;
  String _searchQuery = '';
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLogs() async {
    // Show loading state immediately
    if (mounted && _loading == false) {
      setState(() => _loading = true);
    }

    final logs = await AppLogger.getLogs();
    if (!mounted) return;

    // Parse logs in background isolate
    final result = await _parseLogsInBackground(logs);
    if (!mounted) return;

    setState(() {
      _logs = logs;
      _parsedLogs = result.entries;
      _availableTags = result.tags;
      _applyFilters();
      _loading = false;
    });

    // Scroll to bottom after the frame is rendered
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _applyFilters() {
    var filtered = _parsedLogs;

    // Filter by tag
    if (_selectedTag != null) {
      filtered = filtered.where((e) => e.tag == _selectedTag).toList();
    }

    // Filter by search query
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filtered = filtered
          .where((e) => e.rawLine.toLowerCase().contains(query))
          .toList();
    }

    _filteredLogs = filtered;
  }

  void _onTagSelected(String? tag) {
    setState(() {
      _selectedTag = tag;
      _applyFilters();
    });
  }

  void _onSearchChanged(String query) {
    setState(() {
      _searchQuery = query;
      _applyFilters();
    });
  }

  void _toggleSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchQuery = '';
        _searchController.clear();
        _applyFilters();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search logs...',
                  border: InputBorder.none,
                ),
                onChanged: _onSearchChanged,
              )
            : const Text("App Logs"),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: _toggleSearch,
          ),
          if (!_isSearching)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) async {
                switch (value) {
                  case 'share':
                    if (_logs != null && _logs!.isNotEmpty) {
                      SharePlus.instance.share(
                        ShareParams(text: _logs!, title: 'App Logs'),
                      );
                    }
                    break;
                  case 'delete':
                    AppLogger.clearLogs();
                    _loadLogs();
                    break;
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'share',
                  enabled: _logs != null && _logs!.isNotEmpty,
                  child: const Row(
                    children: [
                      Icon(Icons.share),
                      SizedBox(width: 12),
                      Text('Share logs'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete),
                      SizedBox(width: 12),
                      Text('Clear logs'),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Sticky tag filter
                if (_availableTags.isNotEmpty)
                  Material(
                    elevation: 2,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        border: Border(
                          bottom: BorderSide(
                            color: colorScheme.outlineVariant,
                            width: 1,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Text(
                            'Filter by tag:',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButton<String?>(
                              value: _selectedTag,
                              isExpanded: true,
                              hint: const Text('All tags'),
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text('All tags'),
                                ),
                                ..._availableTags.map((tag) {
                                  return DropdownMenuItem<String?>(
                                    value: tag,
                                    child: Text(tag),
                                  );
                                }),
                              ],
                              onChanged: _onTagSelected,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // Log entries
                Expanded(
                  child: _filteredLogs.isEmpty
                      ? Center(
                          child: Text(
                            _parsedLogs.isEmpty
                                ? 'No logs found'
                                : 'No logs match the current filter',
                            style: theme.textTheme.bodyLarge,
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _loadLogs,
                          child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.all(16),
                            itemCount: _filteredLogs.length,
                            itemBuilder: (context, index) {
                              return _buildLogEntry(_filteredLogs[index]);
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _buildLogEntry(_LogEntry entry) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    const monoStyle = TextStyle(fontFamily: 'monospace', fontSize: 12);

    // If we couldn't parse the log, just show it as plain text
    if (entry.date == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: SelectableText(
          entry.rawLine,
          style: monoStyle.copyWith(
            color: entry.isError ? colorScheme.error : null,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: SelectableText.rich(
        TextSpan(
          children: [
            // Error indicator
            if (entry.isError)
              TextSpan(
                text: '! ',
                style: monoStyle.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.error,
                ),
              ),
            // Date - highlighted
            TextSpan(
              text: '[${entry.date}] ',
              style: monoStyle.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
            // Tag - highlighted
            if (entry.tag != null && entry.tag!.isNotEmpty)
              TextSpan(
                text: '[${entry.tag}] ',
                style: monoStyle.copyWith(
                  color: colorScheme.tertiary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            // Name
            if (entry.name != null && entry.name!.isNotEmpty)
              TextSpan(
                text: '${entry.name}: ',
                style: monoStyle.copyWith(
                  fontWeight: FontWeight.w600,
                  color: entry.isError ? colorScheme.error : null,
                ),
              ),
            // Description - preserve whitespace for multiline content
            if (entry.description != null)
              TextSpan(
                text: entry.description,
                style: monoStyle.copyWith(
                  color: entry.isError ? colorScheme.error : null,
                ),
              ),
          ],
        ),
        // Preserve whitespace and line breaks
        textScaler: TextScaler.noScaling,
      ),
    );
  }
}
