/// Service for secure note sharing.
///
/// Handles creating share links, encrypting content with one-time keys,
/// and managing access requests and approvals.
library;

import 'dart:async';
import 'dart:convert';
import 'package:better_keep/models/note.dart';
import 'package:better_keep/models/note_attachment.dart';
import 'package:better_keep/models/share_link.dart';
import 'package:better_keep/services/auth_service.dart';
import 'package:better_keep/services/e2ee/crypto_primitives.dart' as crypto;
import 'package:better_keep/services/encrypted_file_storage.dart';
import 'package:better_keep/services/export_data_service.dart';
import 'package:better_keep/services/file_system.dart';
import 'package:better_keep/services/firebase_emulator_config.dart';
import 'package:better_keep/firebase_options.dart';
import 'package:better_keep/utils/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'dart:io' show Platform;

/// Result of creating a share link
class ShareLinkResult {
  /// The share URL to give to recipient
  final String shareUrl;

  /// The share ID
  final String shareId;

  /// The share key (base64 encoded) - this is in the URL fragment
  final String shareKey;

  ShareLinkResult({
    required this.shareUrl,
    required this.shareId,
    required this.shareKey,
  });
}

/// AES-GCM encryption for shares (Web Crypto API compatible)
class _ShareCrypto {
  static final _algorithm = AesGcm.with256bits();

  /// Encrypts plaintext using AES-256-GCM
  static Future<({String ciphertext, String nonce})> encrypt(
    String plaintext,
    Uint8List key,
  ) async {
    final secretKey = SecretKey(key);
    final plaintextBytes = utf8.encode(plaintext);

    final secretBox = await _algorithm.encrypt(
      plaintextBytes,
      secretKey: secretKey,
    );

    // Combine ciphertext and MAC (Web Crypto expects this format)
    final combined = Uint8List.fromList([
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);

    return (
      ciphertext: base64Encode(combined),
      nonce: base64Encode(secretBox.nonce),
    );
  }

  /// Encrypts binary data using AES-256-GCM
  /// Returns the encrypted bytes with nonce prepended (first 12 bytes)
  static Future<Uint8List> encryptBytes(Uint8List data, Uint8List key) async {
    final secretKey = SecretKey(key);

    final secretBox = await _algorithm.encrypt(data, secretKey: secretKey);

    // Format: nonce (12 bytes) + ciphertext + MAC (16 bytes)
    return Uint8List.fromList([
      ...secretBox.nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
  }

  /// Decrypts ciphertext using AES-256-GCM
  static Future<String> decrypt(
    String ciphertextBase64,
    String nonceBase64,
    Uint8List key,
  ) async {
    final secretKey = SecretKey(key);
    final combined = base64Decode(ciphertextBase64);
    final nonce = base64Decode(nonceBase64);

    // Split ciphertext and MAC (last 16 bytes is MAC)
    final cipherText = combined.sublist(0, combined.length - 16);
    final mac = Mac(combined.sublist(combined.length - 16));

    final secretBox = SecretBox(cipherText, nonce: nonce, mac: mac);
    final plaintext = await _algorithm.decrypt(secretBox, secretKey: secretKey);

    return utf8.decode(plaintext);
  }
}

/// Service for managing note sharing
class NoteShareService {
  static final NoteShareService _instance = NoteShareService._internal();
  factory NoteShareService() => _instance;
  NoteShareService._internal();

  // Lazy Firestore instance getter to ensure correct databaseId is used
  FirebaseFirestore? _firestoreInstance;
  FirebaseFirestore get _firestore {
    if (_firestoreInstance == null) {
      final dbId = DefaultFirebaseOptions.databaseId;
      AppLogger.log(
        'NoteShareService: Creating Firestore instance with databaseId: $dbId',
      );
      _firestoreInstance = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: dbId,
      );
    }
    return _firestoreInstance!;
  }

  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Base URL for share links - uses hosting emulator in debug mode
  String get _shareBaseUrl {
    if (kDebugMode && FirebaseEmulatorConfig.isUsingEmulators) {
      // Use Firebase Hosting emulator which serves static files like web/s/index.html
      return 'http://localhost:5002/s';
    }
    return 'https://betterkeep.app/s';
  }

  /// Collection reference for shares
  CollectionReference<Map<String, dynamic>> get _sharesCollection =>
      _firestore.collection('shares');

  /// Pending share access requests (for approved devices to monitor)
  final ValueNotifier<List<ShareAccessRequest>> pendingRequests = ValueNotifier(
    [],
  );

  /// Active shares created by this user
  final ValueNotifier<List<ShareLink>> activeShares = ValueNotifier([]);

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _pendingRequestsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _activeSharesSubscription;

  /// Initialize the service and start listening for pending requests
  Future<void> init() async {
    final user = AuthService.currentUser;
    if (user == null) return;

    _listenForPendingRequests();
    _listenForActiveShares();
  }

  /// Dispose subscriptions
  void dispose() {
    _pendingRequestsSubscription?.cancel();
    _activeSharesSubscription?.cancel();
    // Clear cached Firestore instance so a fresh one is created after signout/signin
    _firestoreInstance = null;
  }

  /// Get existing active share link for a note (if any)
  ///
  /// Returns null if no active share exists for this note
  /// Get all active (non-expired) shares for a note
  /// Returns empty list if none found
  Future<List<ShareLink>> getExistingSharesForNote(String noteId) async {
    final user = AuthService.currentUser;
    if (user == null) return [];

    try {
      // Get shares sorted by creation date (newest first)
      final query = await _sharesCollection
          .where('owner_uid', isEqualTo: user.uid)
          .where('note_id', isEqualTo: noteId)
          .where('status', isEqualTo: 'active')
          .orderBy('created_at', descending: true)
          .get();

      AppLogger.log(
        'NoteShareService: Found ${query.docs.length} active shares for note $noteId',
      );

      final shares = <ShareLink>[];
      for (final doc in query.docs) {
        final share = ShareLink.fromFirestore(doc);
        // Only include non-expired shares
        if (!share.isExpired) {
          shares.add(share);
        }
      }
      return shares;
    } catch (e) {
      AppLogger.log('NoteShareService: Error checking existing shares: $e');
      return [];
    }
  }

  /// Get the share URL for an existing share
  ///
  /// Note: The share key is not stored, so this returns just the base URL.
  /// The original key is needed to access the content.
  String getShareUrl(String shareId) {
    return '$_shareBaseUrl/$shareId';
  }

  /// Store the share key locally for a share ID
  /// This allows users to retrieve their share links later
  Future<void> _storeShareKey(
    String shareId,
    String shareKey,
    DateTime expiresAt,
  ) async {
    AppLogger.log('NoteShareService: Storing share key for $shareId...');
    final prefs = await SharedPreferences.getInstance();

    // Store the key
    final keyStored = await prefs.setString('share_key_$shareId', shareKey);
    AppLogger.log('NoteShareService: Key stored: $keyStored');

    // Store expiration timestamp
    final expiryStored = await prefs.setInt(
      'share_expires_$shareId',
      expiresAt.millisecondsSinceEpoch,
    );
    AppLogger.log(
      'NoteShareService: Expiry stored: $expiryStored (${expiresAt.millisecondsSinceEpoch})',
    );

    // Store the full URL for quick access
    final fullUrl = '$_shareBaseUrl/$shareId#$shareKey';
    final urlStored = await prefs.setString('share_url_$shareId', fullUrl);
    AppLogger.log('NoteShareService: URL stored: $urlStored ($fullUrl)');

    AppLogger.log(
      'NoteShareService: Stored share key for $shareId, expires: $expiresAt',
    );

    // Verify storage immediately
    final verifyKey = prefs.getString('share_key_$shareId');
    final verifyExpiry = prefs.getInt('share_expires_$shareId');
    final verifyUrl = prefs.getString('share_url_$shareId');
    AppLogger.log(
      'NoteShareService: Verify - key: ${verifyKey != null}, expiry: $verifyExpiry, url: ${verifyUrl != null}',
    );

    // Clean up expired entries in the background
    _cleanupExpiredShareKeys();
  }

  /// Clean up expired share keys from local storage
  Future<void> _cleanupExpiredShareKeys() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final key in keys) {
        if (key.startsWith('share_expires_')) {
          final expiresAt = prefs.getInt(key);
          if (expiresAt != null && expiresAt < now) {
            // Extract share ID and remove all related keys
            final shareId = key.replaceFirst('share_expires_', '');
            await prefs.remove('share_key_$shareId');
            await prefs.remove('share_expires_$shareId');
            await prefs.remove('share_url_$shareId');
            AppLogger.log(
              'NoteShareService: Cleaned up expired share key for $shareId',
            );
          }
        }
      }
    } catch (e) {
      AppLogger.log(
        'NoteShareService: Error cleaning up expired share keys: $e',
      );
    }
  }

  /// Retrieve a stored share key for a share ID
  /// Returns null if the key is not stored locally or has expired
  Future<String?> getStoredShareKey(String shareId) async {
    final prefs = await SharedPreferences.getInstance();

    // Check if expired
    final expiresAt = prefs.getInt('share_expires_$shareId');
    if (expiresAt != null &&
        expiresAt < DateTime.now().millisecondsSinceEpoch) {
      // Clean up expired entry
      await prefs.remove('share_key_$shareId');
      await prefs.remove('share_expires_$shareId');
      await prefs.remove('share_url_$shareId');
      AppLogger.log(
        'NoteShareService: Share key for $shareId has expired, removed',
      );
      return null;
    }

    final key = prefs.getString('share_key_$shareId');
    AppLogger.log(
      'NoteShareService: Retrieved share key for $shareId: ${key != null ? 'found' : 'not found'}',
    );
    return key;
  }

  /// Get the full share URL directly from storage
  /// Returns null if not stored or expired
  Future<String?> getStoredShareUrl(String shareId) async {
    final prefs = await SharedPreferences.getInstance();

    AppLogger.log('NoteShareService: getStoredShareUrl for $shareId');

    // Check if expired
    final expiresAt = prefs.getInt('share_expires_$shareId');
    AppLogger.log('NoteShareService: Expiry timestamp: $expiresAt');

    if (expiresAt != null &&
        expiresAt < DateTime.now().millisecondsSinceEpoch) {
      // Clean up expired entry
      await prefs.remove('share_key_$shareId');
      await prefs.remove('share_expires_$shareId');
      await prefs.remove('share_url_$shareId');
      AppLogger.log('NoteShareService: Share expired, cleaned up');
      return null;
    }

    final url = prefs.getString('share_url_$shareId');
    AppLogger.log(
      'NoteShareService: Stored URL: ${url != null ? 'found' : 'not found'}',
    );
    return url;
  }

  /// Get the full share URL with key for an existing share
  /// Returns null if the share key is not stored locally
  Future<String?> getFullShareUrl(String shareId) async {
    final shareKey = await getStoredShareKey(shareId);
    if (shareKey == null) return null;
    return '$_shareBaseUrl/$shareId#$shareKey';
  }

  /// Create a share link for a note
  ///
  /// Returns the share URL with the encryption key in the fragment.
  /// The key never goes to the server - only the encrypted content does.
  Future<ShareLinkResult> createShareLink({
    required Note note,
    required ShareDuration duration,
    bool allowModification = false,
    bool includeAttachments = false,
    bool shareAsMarkdown = true,
  }) async {
    final user = AuthService.currentUser;
    if (user == null) {
      throw StateError('User not logged in');
    }

    AppLogger.log('NoteShareService: Creating share link for note ${note.id}');

    // 1. Generate a random share key (32 bytes = 256 bits)
    final shareKey = crypto.SecureRandom.instance.nextBytes(32);
    final shareKeyBase64 = base64UrlEncode(shareKey);

    // 2. Prepare content to encrypt
    String contentToEncrypt;
    if (shareAsMarkdown) {
      // Convert note to markdown for sharing (without attachments/metadata footer)
      contentToEncrypt = ExportDataService().noteToMarkdown(
        note,
        includeMetadata: false,
      );
    } else {
      // Share as JSON (includes all metadata)
      contentToEncrypt = json.encode({
        'title': note.title,
        'content': note.content,
        'plainText': note.plainText,
        'labels': note.labels,
        'createdAt': note.createdAt?.toIso8601String(),
        'updatedAt': note.updatedAt?.toIso8601String(),
      });
    }

    // 3. Encrypt the content with the share key (using AES-GCM for web compatibility)
    final encryptedResult = await _ShareCrypto.encrypt(
      contentToEncrypt,
      shareKey,
    );

    // 4. Handle attachments if requested
    String? encryptedAttachments;
    String? encryptedAttachmentsNonce;
    List<String>? attachmentPaths;

    AppLogger.log(
      'NoteShareService: includeAttachments=$includeAttachments, note.attachments.length=${note.attachments.length}',
    );

    if (includeAttachments && note.attachments.isNotEmpty) {
      // Generate share ID early so we can use it for storage paths
      final shareId = const Uuid().v4().replaceAll('-', '').substring(0, 12);

      // Upload encrypted attachments to storage
      final uploadedAttachments = await _uploadEncryptedAttachments(
        note.attachments,
        shareId,
        shareKey,
      );

      if (uploadedAttachments.isNotEmpty) {
        // Create attachment metadata with storage paths
        final attachmentsMeta = uploadedAttachments;
        final attachmentsJson = json.encode(attachmentsMeta);

        final attachmentsEncrypted = await _ShareCrypto.encrypt(
          attachmentsJson,
          shareKey,
        );
        encryptedAttachments = attachmentsEncrypted.ciphertext;
        encryptedAttachmentsNonce = attachmentsEncrypted.nonce;
        attachmentPaths = uploadedAttachments
            .map((a) => a['storagePath'] as String)
            .toList();

        // 5-8 use the pre-generated shareId
        final now = DateTime.now();
        final expiresAt = now.add(duration.duration);

        final shareLink = ShareLink(
          id: shareId,
          ownerUid: user.uid,
          noteId: note.id?.toString() ?? '',
          noteTitle: note.title,
          encryptedContent: encryptedResult.ciphertext,
          encryptedContentNonce: encryptedResult.nonce,
          encryptedAttachments: encryptedAttachments,
          encryptedAttachmentsNonce: encryptedAttachmentsNonce,
          attachmentPaths: attachmentPaths,
          allowModification: allowModification,
          status: ShareStatus.active,
          createdAt: now,
          expiresAt: expiresAt,
        );

        await _sharesCollection.doc(shareId).set(shareLink.toFirestore());

        AppLogger.log('NoteShareService: Share link created: $shareId');

        final shareUrl = '$_shareBaseUrl/$shareId#$shareKeyBase64';

        // Store the share key locally for later retrieval
        await _storeShareKey(shareId, shareKeyBase64, expiresAt);

        return ShareLinkResult(
          shareUrl: shareUrl,
          shareId: shareId,
          shareKey: shareKeyBase64,
        );
      }
    }

    // 5. Generate share ID (if not already generated for attachments)
    final shareId = const Uuid().v4().replaceAll('-', '').substring(0, 12);

    // 6. Calculate expiration
    final now = DateTime.now();
    final expiresAt = now.add(duration.duration);

    // 7. Create share document in Firestore
    final shareLink = ShareLink(
      id: shareId,
      ownerUid: user.uid,
      noteId: note.id?.toString() ?? '',
      noteTitle: note.title,
      encryptedContent: encryptedResult.ciphertext,
      encryptedContentNonce: encryptedResult.nonce,
      encryptedAttachments: encryptedAttachments,
      encryptedAttachmentsNonce: encryptedAttachmentsNonce,
      attachmentPaths: attachmentPaths,
      allowModification: allowModification,
      status: ShareStatus.active,
      createdAt: now,
      expiresAt: expiresAt,
    );

    AppLogger.log('NoteShareService: Writing share to Firestore: $shareId');
    try {
      await _sharesCollection.doc(shareId).set(shareLink.toFirestore());
      AppLogger.log(
        'NoteShareService: Share link created successfully: $shareId',
      );
    } catch (e) {
      AppLogger.log('NoteShareService: Failed to write share to Firestore: $e');
      rethrow;
    }

    // 8. Construct the share URL
    // The key is in the fragment (#) so it's never sent to server
    final shareUrl = '$_shareBaseUrl/$shareId#$shareKeyBase64';

    // Store the share key locally for later retrieval
    await _storeShareKey(shareId, shareKeyBase64, expiresAt);

    AppLogger.log('NoteShareService: Returning share URL: $shareUrl');

    return ShareLinkResult(
      shareUrl: shareUrl,
      shareId: shareId,
      shareKey: shareKeyBase64,
    );
  }

  /// Upload encrypted attachments to Firebase Storage
  /// Upload encrypted attachments to Firebase Storage
  /// Throws an exception if any attachment fails to upload, and cleans up any already-uploaded files
  Future<List<Map<String, dynamic>>> _uploadEncryptedAttachments(
    List<NoteAttachment> attachments,
    String shareId,
    Uint8List shareKey,
  ) async {
    final List<Map<String, dynamic>> uploadedAttachments = [];
    final List<String> uploadedPaths = []; // Track paths for cleanup on failure
    final fs = await fileSystem();

    // Debug: Check auth status before upload
    final user = FirebaseAuth.instance.currentUser;
    AppLogger.log(
      'NoteShareService: Upload auth check - user: ${user?.uid}, isAnonymous: ${user?.isAnonymous}',
    );
    if (user == null) {
      throw Exception('User not authenticated - cannot upload attachments');
    }

    for (int i = 0; i < attachments.length; i++) {
      final attachment = attachments[i];

      // Get the source path for this attachment
      String? sourcePath;
      String? mimeType;
      String filename;

      switch (attachment.type) {
        case AttachmentType.image:
          sourcePath = attachment.image?.src;
          mimeType = 'image/jpeg';
          filename = 'image_$i.jpg';
        case AttachmentType.sketch:
          sourcePath = attachment.sketch?.previewImage;
          mimeType = 'image/png';
          filename = 'sketch_$i.png';
        case AttachmentType.audio:
          sourcePath = attachment.recording?.src;
          mimeType = 'audio/m4a';
          filename = 'audio_$i.m4a';
      }

      if (sourcePath == null) {
        AppLogger.log(
          'NoteShareService: Skipping attachment $i - no source path',
        );
        continue;
      }

      try {
        // Read the file bytes (handles decryption if locally encrypted)
        Uint8List fileBytes;
        try {
          fileBytes = await readEncryptedBytes(sourcePath);
        } catch (e) {
          // Fall back to raw read if not encrypted
          fileBytes = await fs.readBytes(sourcePath);
        }

        // Encrypt with share key
        final encryptedBytes = await _ShareCrypto.encryptBytes(
          fileBytes,
          shareKey,
        );

        // Upload to Firebase Storage (path includes userId for security rules verification)
        final storagePath = 'shares/${user.uid}/$shareId/attachments/$filename';
        AppLogger.log(
          'NoteShareService: Uploading to storagePath: $storagePath',
        );
        final ref = _storage.ref().child(storagePath);

        await ref.putData(
          encryptedBytes,
          SettableMetadata(
            contentType: 'application/octet-stream',
            customMetadata: {'originalMimeType': mimeType, 'encrypted': 'true'},
          ),
        );

        // Track this path for potential cleanup
        uploadedPaths.add(storagePath);

        // Get download URL
        final downloadUrl = await ref.getDownloadURL();

        // Add to uploaded list with metadata
        uploadedAttachments.add({
          'type': attachment.type.name,
          'storagePath': storagePath,
          'downloadUrl': downloadUrl,
          'mimeType': mimeType,
          'filename': filename,
          'index': i,
          // Include original metadata for display
          if (attachment.image != null)
            'aspectRatio': attachment.image!.aspectRatio,
          if (attachment.recording?.title != null)
            'title': attachment.recording!.title,
        });

        AppLogger.log(
          'NoteShareService: Uploaded attachment $i to $storagePath',
        );
      } catch (e) {
        AppLogger.log('NoteShareService: Failed to upload attachment $i: $e');

        // Clean up any attachments that were already uploaded
        if (uploadedPaths.isNotEmpty) {
          AppLogger.log(
            'NoteShareService: Cleaning up ${uploadedPaths.length} already-uploaded attachments',
          );
          for (final path in uploadedPaths) {
            try {
              await _storage.ref().child(path).delete();
            } catch (deleteError) {
              AppLogger.log(
                'NoteShareService: Failed to cleanup $path: $deleteError',
              );
            }
          }
        }

        // Re-throw with a user-friendly message
        throw Exception(
          'Failed to upload attachment ${i + 1} of ${attachments.length}. '
          'Please check your internet connection and storage permissions.',
        );
      }
    }

    return uploadedAttachments;
  }

  /// Get a share link by ID
  Future<ShareLink?> getShareLink(String shareId) async {
    final doc = await _sharesCollection.doc(shareId).get();
    if (!doc.exists) return null;
    return ShareLink.fromFirestore(doc);
  }

  /// Revoke a share link
  Future<void> revokeShareLink(String shareId) async {
    final user = AuthService.currentUser;
    if (user == null) throw StateError('User not logged in');

    final doc = await _sharesCollection.doc(shareId).get();
    if (!doc.exists) throw StateError('Share not found');

    final share = ShareLink.fromFirestore(doc);
    if (share.ownerUid != user.uid) {
      throw StateError('Not authorized to revoke this share');
    }

    await _sharesCollection.doc(shareId).update({
      'status': ShareStatus.revoked.name,
      'revoked_at': DateTime.now().toIso8601String(),
    });

    AppLogger.log('NoteShareService: Share link revoked: $shareId');
  }

  /// Revoke all share links for a specific note
  /// Called when a note is moved to trash or deleted
  Future<void> revokeAllSharesForNote(String noteId) async {
    final user = AuthService.currentUser;
    if (user == null) return;

    try {
      final query = await _sharesCollection
          .where('owner_uid', isEqualTo: user.uid)
          .where('note_id', isEqualTo: noteId)
          .where('status', isEqualTo: 'active')
          .get();

      if (query.docs.isEmpty) {
        AppLogger.log(
          'NoteShareService: No active shares to revoke for note $noteId',
        );
        return;
      }

      AppLogger.log(
        'NoteShareService: Revoking ${query.docs.length} shares for note $noteId',
      );

      final batch = _firestore.batch();
      final now = DateTime.now().toIso8601String();

      for (final doc in query.docs) {
        batch.update(doc.reference, {
          'status': ShareStatus.revoked.name,
          'revoked_at': now,
        });
      }

      await batch.commit();
      AppLogger.log('NoteShareService: All shares revoked for note $noteId');
    } catch (e) {
      AppLogger.log(
        'NoteShareService: Error revoking shares for note $noteId: $e',
      );
    }
  }

  /// Delete a share link completely
  Future<void> deleteShareLink(String shareId) async {
    final user = AuthService.currentUser;
    if (user == null) throw StateError('User not logged in');

    final doc = await _sharesCollection.doc(shareId).get();
    if (!doc.exists) return;

    final share = ShareLink.fromFirestore(doc);
    if (share.ownerUid != user.uid) {
      throw StateError('Not authorized to delete this share');
    }

    // Delete attachment files from storage
    await _deleteShareAttachments(shareId, share.attachmentPaths);

    // Delete all requests for this share
    final requests = await _sharesCollection
        .doc(shareId)
        .collection('requests')
        .get();
    for (final request in requests.docs) {
      await request.reference.delete();
    }

    // Delete the share itself
    await _sharesCollection.doc(shareId).delete();

    AppLogger.log('NoteShareService: Share link deleted: $shareId');
  }

  /// Delete share attachment files from storage
  Future<void> _deleteShareAttachments(
    String shareId,
    List<String>? attachmentPaths,
  ) async {
    if (attachmentPaths == null || attachmentPaths.isEmpty) return;

    for (final path in attachmentPaths) {
      try {
        await _storage.ref().child(path).delete();
        AppLogger.log('NoteShareService: Deleted attachment: $path');
      } catch (e) {
        AppLogger.log(
          'NoteShareService: Failed to delete attachment $path: $e',
        );
        // Continue with other deletions
      }
    }

    // Also try to delete the folder
    try {
      final user = AuthService.currentUser;
      if (user != null) {
        final folderRef = _storage.ref().child(
          'shares/${user.uid}/$shareId/attachments',
        );
        final list = await folderRef.listAll();
        for (final item in list.items) {
          await item.delete();
        }
      }
    } catch (e) {
      // Folder might already be empty
    }
  }

  /// Request access to a shared note
  Future<String> requestAccess({
    required String shareId,
    required String deviceName,
    required String platform,
  }) async {
    final requestId = const Uuid().v4();

    final request = ShareAccessRequest(
      id: requestId,
      shareId: shareId,
      deviceName: deviceName,
      platform: platform,
      status: ShareAccessStatus.pending,
      requestedAt: DateTime.now(),
    );

    await _sharesCollection
        .doc(shareId)
        .collection('requests')
        .doc(requestId)
        .set(request.toFirestore());

    AppLogger.log('NoteShareService: Access requested for share: $shareId');

    return requestId;
  }

  /// Approve an access request
  Future<void> approveRequest(String shareId, String requestId) async {
    final user = AuthService.currentUser;
    if (user == null) throw StateError('User not logged in');

    // Verify ownership
    final shareDoc = await _sharesCollection.doc(shareId).get();
    if (!shareDoc.exists) throw StateError('Share not found');

    final share = ShareLink.fromFirestore(shareDoc);
    if (share.ownerUid != user.uid) {
      throw StateError('Not authorized to approve this request');
    }

    await _sharesCollection
        .doc(shareId)
        .collection('requests')
        .doc(requestId)
        .update({
          'status': ShareAccessStatus.approved.name,
          'responded_at': DateTime.now().toIso8601String(),
        });

    AppLogger.log('NoteShareService: Access approved for request: $requestId');

    // Manually refresh pending requests since the listener won't catch this
    _refreshPendingRequests();
  }

  /// Deny an access request
  Future<void> denyRequest(String shareId, String requestId) async {
    final user = AuthService.currentUser;
    if (user == null) throw StateError('User not logged in');

    // Verify ownership
    final shareDoc = await _sharesCollection.doc(shareId).get();
    if (!shareDoc.exists) throw StateError('Share not found');

    final share = ShareLink.fromFirestore(shareDoc);
    if (share.ownerUid != user.uid) {
      throw StateError('Not authorized to deny this request');
    }

    await _sharesCollection
        .doc(shareId)
        .collection('requests')
        .doc(requestId)
        .update({
          'status': ShareAccessStatus.denied.name,
          'responded_at': DateTime.now().toIso8601String(),
        });

    AppLogger.log('NoteShareService: Access denied for request: $requestId');

    // Manually refresh pending requests since the listener won't catch this
    _refreshPendingRequests();
  }

  /// Manually refresh pending requests
  Future<void> _refreshPendingRequests() async {
    final user = AuthService.currentUser;
    if (user == null) return;

    try {
      final sharesSnapshot = await _sharesCollection
          .where('owner_uid', isEqualTo: user.uid)
          .where('status', isEqualTo: ShareStatus.active.name)
          .get();

      final allPendingRequests = <ShareAccessRequest>[];

      for (final shareDoc in sharesSnapshot.docs) {
        final shareId = shareDoc.id;

        final requestsSnapshot = await _sharesCollection
            .doc(shareId)
            .collection('requests')
            .where('status', isEqualTo: ShareAccessStatus.pending.name)
            .get();

        for (final requestDoc in requestsSnapshot.docs) {
          allPendingRequests.add(ShareAccessRequest.fromFirestore(requestDoc));
        }
      }

      pendingRequests.value = allPendingRequests;
    } catch (e) {
      AppLogger.log('NoteShareService: Error refreshing pending requests: $e');
    }
  }

  /// Get the status of an access request
  Future<ShareAccessRequest?> getRequestStatus(
    String shareId,
    String requestId,
  ) async {
    final doc = await _sharesCollection
        .doc(shareId)
        .collection('requests')
        .doc(requestId)
        .get();

    if (!doc.exists) return null;
    return ShareAccessRequest.fromFirestore(doc);
  }

  /// Decrypt share content using the share key from URL fragment
  Future<String> decryptShareContent({
    required ShareLink share,
    required String shareKeyBase64,
  }) async {
    final shareKey = base64Url.decode(shareKeyBase64);

    final decrypted = await _ShareCrypto.decrypt(
      share.encryptedContent,
      share.encryptedContentNonce,
      Uint8List.fromList(shareKey),
    );

    return decrypted;
  }

  /// Listen for pending access requests on shares owned by this user
  void _listenForPendingRequests() {
    final user = AuthService.currentUser;
    if (user == null) return;

    _pendingRequestsSubscription?.cancel();

    // First, get all active shares owned by this user
    _sharesCollection
        .where('owner_uid', isEqualTo: user.uid)
        .where('status', isEqualTo: ShareStatus.active.name)
        .snapshots()
        .listen((sharesSnapshot) async {
          final allPendingRequests = <ShareAccessRequest>[];

          for (final shareDoc in sharesSnapshot.docs) {
            final shareId = shareDoc.id;

            // Get pending requests for this share
            final requestsSnapshot = await _sharesCollection
                .doc(shareId)
                .collection('requests')
                .where('status', isEqualTo: ShareAccessStatus.pending.name)
                .get();

            for (final requestDoc in requestsSnapshot.docs) {
              allPendingRequests.add(
                ShareAccessRequest.fromFirestore(requestDoc),
              );
            }
          }

          pendingRequests.value = allPendingRequests;
        });
  }

  /// Listen for active shares owned by this user
  void _listenForActiveShares() {
    final user = AuthService.currentUser;
    if (user == null) return;

    _activeSharesSubscription?.cancel();
    _activeSharesSubscription = _sharesCollection
        .where('owner_uid', isEqualTo: user.uid)
        .orderBy('created_at', descending: true)
        .snapshots()
        .listen((snapshot) {
          activeShares.value = snapshot.docs
              .map((doc) => ShareLink.fromFirestore(doc))
              .toList();
        });
  }

  /// Get the current device name
  String getDeviceName() {
    if (kIsWeb) {
      return 'Web Browser';
    }
    try {
      if (Platform.isAndroid) return 'Android Device';
      if (Platform.isIOS) return 'iPhone/iPad';
      if (Platform.isMacOS) return 'Mac';
      if (Platform.isWindows) return 'Windows PC';
      if (Platform.isLinux) return 'Linux';
    } catch (_) {}
    return 'Unknown Device';
  }

  /// Get the current platform name
  String getPlatformName() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
    } catch (_) {}
    return 'unknown';
  }
}
