/// Wire limits are checked before buffering/decrypting provider-controlled data.
/// A single media object is limited to 256 MiB; commits are metadata only.
abstract final class SyncLimits {
  static const objectBytes = 256 * 1024 * 1024;
  static const commitBytes = 512 * 1024;
  static const metadataBytes = 8 * 1024 * 1024;
  static const attachmentCount = 1024;
}
