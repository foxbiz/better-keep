import 'dart:convert';
import 'package:better_keep/services/file_system/file_system.dart';
import 'package:better_keep/state.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;

class AppLogger {
  /// Maximum log file size in bytes (1MB)
  static const int _maxLogSize = 1024 * 1024;

  static String get _logPath => path.join(AppState.cacheDir, 'log.txt');

  static String get _oldLogPath => path.join(AppState.cacheDir, 'log.old.txt');

  static Future<void> log(String message) async {
    await _writeLog(message, isError: false);
  }

  /// Log an error message (similar to console.error in JS)
  /// Error logs are marked with '!' prefix for identification
  static Future<void> error(
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) async {
    final errorMessage = error != null
        ? '$message: $error${stackTrace != null ? '\n$stackTrace' : ''}'
        : message;
    await _writeLog(errorMessage, isError: true);
  }

  static Future<void> _writeLog(String message, {required bool isError}) async {
    final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    // Add '!' prefix for error logs to identify them when reading
    final prefix = isError ? '!' : '';
    final logMessage = "$prefix[$timestamp] $message";

    if (kDebugMode) {
      debugPrint(logMessage);
    }

    try {
      final fs = await fileSystem();

      // Check if log rotation is needed
      await _rotateLogIfNeeded(fs, _logPath);

      // Append to file
      await fs.writeString(_logPath, '$logMessage\n', append: true);
    } catch (e) {
      debugPrint("Failed to write log to file: $e");
    }
  }

  /// Rotates the log file if it exceeds the maximum size
  static Future<void> _rotateLogIfNeeded(FileSystem fs, String logPath) async {
    try {
      if (!await fs.exists(logPath)) return;

      // Read as bytes and decode with error handling for non-UTF-8 data
      final bytes = await fs.readBytes(logPath);
      if (bytes.length > _maxLogSize) {
        final content = utf8.decode(bytes, allowMalformed: true);
        // Move current log to old log (overwrite)
        final oldLogPath = _oldLogPath;
        // Keep only the last half of the log
        final truncatedContent = content.substring(content.length ~/ 2);
        await fs.writeString(oldLogPath, truncatedContent);
        // Clear current log
        await fs.delete(logPath);
      }
    } catch (e) {
      debugPrint("Failed to rotate log: $e");
    }
  }

  static Future<String> getLogs() async {
    try {
      final fs = await fileSystem();
      final logPath = await _logPath;
      if (await fs.exists(logPath)) {
        // Read as bytes and decode with error handling for non-UTF-8 data
        final bytes = await fs.readBytes(logPath);
        return utf8.decode(bytes, allowMalformed: true);
      }
      return "No logs found.";
    } catch (e) {
      return "Error reading logs: $e";
    }
  }

  static Future<void> clearLogs() async {
    try {
      final fs = await fileSystem();
      final logPath = await _logPath;
      if (await fs.exists(logPath)) {
        await fs.delete(logPath);
      }
    } catch (e) {
      debugPrint("Failed to clear logs: $e");
    }
  }
}
