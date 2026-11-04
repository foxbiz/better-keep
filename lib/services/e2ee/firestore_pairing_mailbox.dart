import 'device_pairing_channel.dart';
import 'device_verification.dart';
import '../cloud_read.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

/// An owner-scoped mailbox, not a trust source. No server or rules change is
/// needed: device documents already permit the signed-in account to coordinate.
class FirestorePairingMailbox implements PairingCodeMailbox {
  FirestorePairingMailbox(this.reference, this.request, this.isCurrent);
  final DocumentReference<Map<String, dynamic>> reference;
  final DeviceVerificationRequest request;
  final bool Function() isCurrent;

  Map<String, dynamic>? _read(Map<String, dynamic>? data) {
    if (!isCurrent() ||
        data?['status'] != 'pending' ||
        data?['public_key'] != request.publicKey ||
        data?['approval_protocol'] != DeviceVerificationRequest.version ||
        data?['approval_request'] is! Map ||
        DeviceVerificationRequest.fromJson(
              Map<String, dynamic>.from(data!['approval_request'] as Map),
            ).canonical !=
            request.canonical) {
      throw StateError('Device pairing request changed');
    }
    request.requireValid(DateTime.now());
    final value = data['code_pairing'];
    if (value == null) return null;
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid pairing mailbox');
    }
    return value;
  }

  @override
  Future<Map<String, dynamic>?> read() async =>
      _read((await readCloudDocument(reference, isCurrent: isCurrent)).data());

  @override
  Stream<Map<String, dynamic>?> watch() => reference
      .snapshots(includeMetadataChanges: true)
      .where(
        (snapshot) =>
            !snapshot.metadata.isFromCache &&
            !snapshot.metadata.hasPendingWrites,
      )
      .map((snapshot) => _read(snapshot.data()));

  @override
  Future<void> change(
    Map<String, dynamic>? Function(Map<String, dynamic>?) update,
  ) => reference.firestore
      .runTransaction((transaction) async {
        final data = (await transaction.get(reference)).data();
        final next = update(_read(data));
        if (!isCurrent()) throw StateError('Device pairing session ended');
        transaction.update(reference, {
          'code_pairing': next ?? FieldValue.delete(),
        });
      })
      .timeout(const Duration(seconds: 15));
}
