/// Note encryption and decryption for E2EE.
///
/// Encrypts note content before sending to Firestore and decrypts on retrieval.
library;

import 'dart:convert';

import 'package:better_keep/services/e2ee/crypto_primitives.dart';
import 'package:better_keep/services/e2ee/device_manager.dart';
import 'package:better_keep/utils/logger.dart';

/// Encrypted note data for Firestore storage.
class EncryptedNoteData {
  /// Encrypted content (base64-encoded ciphertext).
  final String ciphertext;

  /// Nonce used for encryption (base64-encoded).
  final String nonce;

  /// Encrypted title (base64-encoded ciphertext), if title exists.
  final String? titleCiphertext;

  /// Nonce for title encryption (base64-encoded), if title exists.
  final String? titleNonce;

  /// E2EE version for future compatibility.
  final int version;

  EncryptedNoteData({
    required this.ciphertext,
    required this.nonce,
    this.titleCiphertext,
    this.titleNonce,
    this.version = 1,
  });

  Map<String, dynamic> toFirestore() => {
    'e2ee_ciphertext': ciphertext,
    'e2ee_nonce': nonce,
    if (titleCiphertext != null) 'e2ee_title_ciphertext': titleCiphertext,
    if (titleNonce != null) 'e2ee_title_nonce': titleNonce,
    'e2ee_version': version,
  };

  factory EncryptedNoteData.fromFirestore(Map<String, dynamic> data) {
    return EncryptedNoteData(
      ciphertext: data['e2ee_ciphertext'] as String,
      nonce: data['e2ee_nonce'] as String,
      titleCiphertext: data['e2ee_title_ciphertext'] as String?,
      titleNonce: data['e2ee_title_nonce'] as String?,
      version: data['e2ee_version'] as int? ?? 1,
    );
  }

  /// Checks if the Firestore data contains E2EE encrypted content.
  static bool isEncrypted(Map<String, dynamic> data) {
    return data.containsKey('e2ee_ciphertext') &&
        data.containsKey('e2ee_nonce');
  }
}

/// Decrypted note content.
class DecryptedNoteContent {
  final String? title;
  final String? content;
  final String? plainText;

  DecryptedNoteContent({this.title, this.content, this.plainText});
}

/// Service for encrypting and decrypting notes.
class NoteEncryptionService {
  static NoteEncryptionService? _instance;
  static NoteEncryptionService get instance {
    _instance ??= NoteEncryptionService._();
    return _instance!;
  }

  NoteEncryptionService._();

  final DeviceManager _deviceManager = DeviceManager.instance;

  /// Checks if E2EE is available (UMK is unlocked).
  bool get isE2EEAvailable => _deviceManager.getUMK() != null;

  /// Encrypts note content for storage.
  ///
  /// Returns null if E2EE is not available.
  Future<EncryptedNoteData?> encryptNote({
    String? title,
    String? content,
  }) async {
    final umk = _deviceManager.getUMK();
    if (umk == null) {
      AppLogger.log('E2EE: Cannot encrypt note - UMK not available');
      return null;
    }

    // Combine title and content into a JSON structure for encryption
    final noteData = json.encode({'title': title, 'content': content});

    // Encrypt the combined data
    final encrypted = await AuthenticatedCipher.encryptString(noteData, umk);

    // Optionally encrypt title separately for searchable encryption in the future
    String? titleCiphertext;
    String? titleNonce;
    if (title != null && title.isNotEmpty) {
      final encryptedTitle = await AuthenticatedCipher.encryptString(
        title,
        umk,
      );
      titleCiphertext = encryptedTitle.ciphertext;
      titleNonce = encryptedTitle.nonce;
    }

    return EncryptedNoteData(
      ciphertext: encrypted.ciphertext,
      nonce: encrypted.nonce,
      titleCiphertext: titleCiphertext,
      titleNonce: titleNonce,
    );
  }

  /// Decrypts note content from storage.
  ///
  /// Returns null if E2EE is not available or decryption fails.
  Future<DecryptedNoteContent?> decryptNote(
    EncryptedNoteData encryptedData,
  ) async {
    final umk = _deviceManager.getUMK();
    if (umk == null) {
      AppLogger.log('E2EE: Cannot decrypt note - UMK not available');
      return null;
    }

    try {
      // Decrypt the combined data
      final decryptedJson = await AuthenticatedCipher.decryptString(
        encryptedData.ciphertext,
        encryptedData.nonce,
        umk,
      );

      final noteData = json.decode(decryptedJson) as Map<String, dynamic>;

      final content = noteData['content'] as String?;
      String? plainText;

      // Extract plain text from content if it's Quill delta JSON
      if (content != null && content.isNotEmpty) {
        try {
          final deltaList = json.decode(content) as List;
          final buffer = StringBuffer();
          for (final op in deltaList) {
            if (op is Map<String, dynamic> && op['insert'] is String) {
              buffer.write(op['insert']);
            }
          }
          plainText = buffer.toString().trim();
          if (plainText.length > 500) {
            plainText = '${plainText.substring(0, 500)}...';
          }
        } catch (_) {
          // Content is not valid delta JSON, use as-is
          plainText = content;
        }
      }

      return DecryptedNoteContent(
        title: noteData['title'] as String?,
        content: content,
        plainText: plainText,
      );
    } catch (e, stack) {
      AppLogger.error('E2EE: Failed to decrypt note', e, stack);
      return null;
    }
  }

  /// Decrypts note content directly from Firestore data.
  ///
  /// Returns null if the data is not encrypted or decryption fails.
  Future<DecryptedNoteContent?> decryptNoteFromFirestore(
    Map<String, dynamic> firestoreData,
  ) async {
    if (!EncryptedNoteData.isEncrypted(firestoreData)) {
      // Data is not encrypted, return as-is
      return DecryptedNoteContent(
        title: firestoreData['title'] as String?,
        content: firestoreData['content'] as String?,
        plainText: firestoreData['plain_text'] as String?,
      );
    }

    final encryptedData = EncryptedNoteData.fromFirestore(firestoreData);
    return await decryptNote(encryptedData);
  }

  /// Prepares note data for Firestore upload.
  ///
  /// If E2EE is enabled, encrypts the content and clears plaintext fields.
  /// If E2EE is not enabled, returns the data as-is.
  Future<Map<String, dynamic>> prepareNoteForUpload(
    Map<String, dynamic> noteData,
  ) async {
    if (!isE2EEAvailable) {
      // E2EE not available, upload unencrypted
      return noteData;
    }

    final title = noteData['title'] as String?;
    final content = noteData['content'] as String?;

    final encrypted = await encryptNote(title: title, content: content);
    if (encrypted == null) {
      // Encryption failed, upload unencrypted
      return noteData;
    }

    // Create new data map with encrypted content
    final encryptedData = Map<String, dynamic>.from(noteData);

    // Remove plaintext fields
    encryptedData.remove('title');
    encryptedData.remove('content');
    encryptedData.remove('plain_text');

    // Add encrypted fields
    encryptedData.addAll(encrypted.toFirestore());

    // Add flag to indicate this note is E2EE encrypted
    encryptedData['e2ee_enabled'] = true;

    return encryptedData;
  }

  /// Processes note data from Firestore download.
  ///
  /// If the note is E2EE encrypted, decrypts it.
  /// If not encrypted, returns the data as-is.
  Future<Map<String, dynamic>> processNoteFromDownload(
    Map<String, dynamic> firestoreData,
  ) async {
    if (!EncryptedNoteData.isEncrypted(firestoreData)) {
      // Not encrypted, return as-is
      return firestoreData;
    }

    if (!isE2EEAvailable) {
      // E2EE not available, can't decrypt
      AppLogger.log('E2EE: Received encrypted note but UMK not available');
      // Return with placeholder content
      final processedData = Map<String, dynamic>.from(firestoreData);
      processedData['title'] = '[Encrypted Note]';
      processedData['content'] = null;
      processedData['plain_text'] =
          'This note is encrypted. Please authorize this device to view it.';
      return processedData;
    }

    final decrypted = await decryptNoteFromFirestore(firestoreData);
    if (decrypted == null) {
      // Decryption failed
      final processedData = Map<String, dynamic>.from(firestoreData);
      processedData['title'] = '[Decryption Failed]';
      processedData['content'] = null;
      processedData['plain_text'] = 'Failed to decrypt this note.';
      return processedData;
    }

    // Create new data map with decrypted content
    final processedData = Map<String, dynamic>.from(firestoreData);
    processedData['title'] = decrypted.title;
    processedData['content'] = decrypted.content;
    processedData['plain_text'] = decrypted.plainText;

    return processedData;
  }
}
