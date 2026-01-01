/// Share link model for secure note sharing.
///
/// Stores encrypted note content with a separate share key (not UMK).
/// The share key is only in the URL fragment, never sent to server.
library;

import 'package:cloud_firestore/cloud_firestore.dart';

/// Status of a share link
enum ShareStatus {
  /// Share is active and can be accessed (after approval)
  active,

  /// Share has expired based on expiration time
  expired,

  /// Share was manually revoked by owner
  revoked,
}

/// Status of a share access request
enum ShareAccessStatus {
  /// Request is pending owner approval
  pending,

  /// Request was approved
  approved,

  /// Request was denied
  denied,
}

/// A share link document stored in Firestore.
///
/// Path: /shares/{shareId}
class ShareLink {
  /// Unique share ID (used in URL)
  final String id;

  /// Owner's user ID
  final String ownerUid;

  /// Original note ID (for reference, not for accessing)
  final String noteId;

  /// Note title (unencrypted, for display)
  final String? noteTitle;

  /// Encrypted note content (encrypted with share key, not UMK)
  /// Format: base64 encoded ciphertext
  final String encryptedContent;

  /// Nonce used for encryption
  final String encryptedContentNonce;

  /// Encrypted attachments metadata JSON (optional)
  /// Contains list of attachment info with storage URLs
  final String? encryptedAttachments;

  /// Nonce for attachments encryption
  final String? encryptedAttachmentsNonce;

  /// List of encrypted attachment file paths in storage
  /// Format: shares/{shareId}/attachments/{filename}
  final List<String>? attachmentPaths;

  /// Whether the share allows modification (creates a copy for recipient)
  final bool allowModification;

  /// Share status
  final ShareStatus status;

  /// When the share was created
  final DateTime createdAt;

  /// When the share expires
  final DateTime expiresAt;

  /// When the share was revoked (if applicable)
  final DateTime? revokedAt;

  ShareLink({
    required this.id,
    required this.ownerUid,
    required this.noteId,
    this.noteTitle,
    required this.encryptedContent,
    required this.encryptedContentNonce,
    this.encryptedAttachments,
    this.encryptedAttachmentsNonce,
    this.attachmentPaths,
    this.allowModification = false,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.revokedAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
  bool get isActive => status == ShareStatus.active && !isExpired;
  bool get isRevoked => status == ShareStatus.revoked;

  factory ShareLink.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return ShareLink(
      id: doc.id,
      ownerUid: data['owner_uid'] as String,
      noteId: data['note_id'] as String,
      noteTitle: data['note_title'] as String?,
      encryptedContent: data['encrypted_content'] as String,
      encryptedContentNonce: data['encrypted_content_nonce'] as String,
      encryptedAttachments: data['encrypted_attachments'] as String?,
      encryptedAttachmentsNonce: data['encrypted_attachments_nonce'] as String?,
      attachmentPaths: (data['attachment_paths'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      allowModification: data['allow_modification'] as bool? ?? false,
      status: ShareStatus.values.firstWhere(
        (s) => s.name == data['status'],
        orElse: () => ShareStatus.expired,
      ),
      createdAt: DateTime.parse(data['created_at'] as String),
      expiresAt: DateTime.parse(data['expires_at'] as String),
      revokedAt: data['revoked_at'] != null
          ? DateTime.parse(data['revoked_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toFirestore() => {
    'owner_uid': ownerUid,
    'note_id': noteId,
    'note_title': noteTitle,
    'encrypted_content': encryptedContent,
    'encrypted_content_nonce': encryptedContentNonce,
    'encrypted_attachments': encryptedAttachments,
    'encrypted_attachments_nonce': encryptedAttachmentsNonce,
    if (attachmentPaths != null) 'attachment_paths': attachmentPaths,
    'allow_modification': allowModification,
    'status': status.name,
    'created_at': createdAt.toIso8601String(),
    'expires_at': expiresAt.toIso8601String(),
    if (revokedAt != null) 'revoked_at': revokedAt!.toIso8601String(),
  };

  ShareLink copyWith({ShareStatus? status, DateTime? revokedAt}) {
    return ShareLink(
      id: id,
      ownerUid: ownerUid,
      noteId: noteId,
      noteTitle: noteTitle,
      encryptedContent: encryptedContent,
      encryptedContentNonce: encryptedContentNonce,
      encryptedAttachments: encryptedAttachments,
      encryptedAttachmentsNonce: encryptedAttachmentsNonce,
      attachmentPaths: attachmentPaths,
      allowModification: allowModification,
      status: status ?? this.status,
      createdAt: createdAt,
      expiresAt: expiresAt,
      revokedAt: revokedAt ?? this.revokedAt,
    );
  }
}

/// A share access request from someone trying to access a shared note.
///
/// Path: /shares/{shareId}/requests/{requestId}
class ShareAccessRequest {
  /// Unique request ID
  final String id;

  /// Share ID this request is for
  final String shareId;

  /// Requester's device name
  final String deviceName;

  /// Requester's platform (android, ios, web, etc.)
  final String platform;

  /// Requester's IP address (for display only, from Cloud Function)
  final String? ipAddress;

  /// Approximate location based on IP (for display only)
  final String? location;

  /// Request status
  final ShareAccessStatus status;

  /// When the request was made
  final DateTime requestedAt;

  /// When the request was responded to
  final DateTime? respondedAt;

  ShareAccessRequest({
    required this.id,
    required this.shareId,
    required this.deviceName,
    required this.platform,
    this.ipAddress,
    this.location,
    required this.status,
    required this.requestedAt,
    this.respondedAt,
  });

  bool get isPending => status == ShareAccessStatus.pending;
  bool get isApproved => status == ShareAccessStatus.approved;
  bool get isDenied => status == ShareAccessStatus.denied;

  factory ShareAccessRequest.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    return ShareAccessRequest(
      id: doc.id,
      shareId: data['share_id'] as String,
      deviceName: data['device_name'] as String,
      platform: data['platform'] as String,
      ipAddress: data['ip_address'] as String?,
      location: data['location'] as String?,
      status: ShareAccessStatus.values.firstWhere(
        (s) => s.name == data['status'],
        orElse: () => ShareAccessStatus.pending,
      ),
      requestedAt: DateTime.parse(data['requested_at'] as String),
      respondedAt: data['responded_at'] != null
          ? DateTime.parse(data['responded_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toFirestore() => {
    'share_id': shareId,
    'device_name': deviceName,
    'platform': platform,
    if (ipAddress != null) 'ip_address': ipAddress,
    if (location != null) 'location': location,
    'status': status.name,
    'requested_at': requestedAt.toIso8601String(),
    if (respondedAt != null) 'responded_at': respondedAt!.toIso8601String(),
  };
}

/// Duration options for share link expiration
enum ShareDuration {
  oneHour(Duration(hours: 1), '1 hour'),
  sixHours(Duration(hours: 6), '6 hours'),
  oneDay(Duration(days: 1), '1 day'),
  threeDays(Duration(days: 3), '3 days'),
  oneWeek(Duration(days: 7), '1 week'),
  twoWeeks(Duration(days: 14), '2 weeks'),
  oneMonth(Duration(days: 30), '30 days');

  final Duration duration;
  final String label;

  const ShareDuration(this.duration, this.label);
}
