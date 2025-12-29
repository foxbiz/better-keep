import 'package:better_keep/utils/logger.dart';
import 'package:flutter/material.dart';
import 'package:better_keep/models/note.dart';

/// Dialog for entering a PIN to unlock a note.
class UnlockNoteDialog extends StatefulWidget {
  final Note note;

  const UnlockNoteDialog({super.key, required this.note});

  @override
  State<UnlockNoteDialog> createState() => _UnlockNoteDialogState();
}

class _UnlockNoteDialogState extends State<UnlockNoteDialog> {
  final _pinController = TextEditingController();
  bool _obscurePin = true;
  String? _error;
  int _attempts = 0;
  bool _isLocked = false;
  int _lockSeconds = 0;
  bool _disposed = false;

  static const int _maxAttempts = 5;
  static const List<int> _lockDurations = [
    30,
    60,
    120,
    300,
  ]; // Progressive delays

  @override
  void dispose() {
    _disposed = true;
    _pinController.dispose();
    super.dispose();
  }

  int _getLockDuration() {
    final lockIndex = (_attempts - _maxAttempts).clamp(
      0,
      _lockDurations.length - 1,
    );
    return _lockDurations[lockIndex];
  }

  void _startLockTimer() {
    _lockSeconds = _getLockDuration();
    _isLocked = true;
    setState(() {});

    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      // Stop timer if dialog was disposed
      if (_disposed || !mounted) return false;
      _lockSeconds--;
      if (_lockSeconds <= 0) {
        _isLocked = false;
        setState(() {});
        return false;
      }
      setState(() {});
      return true;
    });
  }

  Future<void> _unlock() async {
    if (_isLocked) {
      setState(() => _error = 'Too many attempts. Wait $_lockSeconds seconds.');
      return;
    }

    if (_pinController.text.isEmpty) {
      setState(() => _error = 'Please enter the PIN');
      return;
    }

    try {
      await widget.note.unlock(_pinController.text);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on FormatException catch (e) {
      _attempts++;
      if (_attempts >= _maxAttempts) {
        _startLockTimer();
        setState(
          () => _error = 'Too many attempts. Wait $_lockSeconds seconds.',
        );
      } else {
        final remaining = _maxAttempts - _attempts;
        setState(() => _error = '${e.message}. $remaining attempts remaining.');
      }
    } catch (e) {
      AppLogger.error("[UnlockNoteDialog] Failed to unlock note: $e");
      _attempts++;
      if (_attempts >= _maxAttempts) {
        _startLockTimer();
        setState(
          () => _error = 'Too many attempts. Wait $_lockSeconds seconds.',
        );
      } else {
        setState(() => _error = 'Failed to unlock note');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Unlock Note'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _pinController,
              obscureText: _obscurePin,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'PIN',
                hintText: 'Enter PIN',
                errorText: _error,
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePin ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(() => _obscurePin = !_obscurePin),
                ),
              ),
              onSubmitted: (_) => _unlock(),
              onChanged: (_) {
                if (_error != null) {
                  setState(() => _error = null);
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLocked ? null : _unlock,
          child: Text(_isLocked ? 'Locked ($_lockSeconds s)' : 'Unlock'),
        ),
      ],
    );
  }
}

/// Shows a dialog to enter a PIN for unlocking a note.
/// Returns true if successfully unlocked, or null if cancelled.
Future<bool?> showUnlockNoteDialog(BuildContext context, Note note) {
  return showDialog<bool?>(
    context: context,
    builder: (context) => UnlockNoteDialog(note: note),
  );
}
