import 'webdav_sync_transport.dart';

/// Nextcloud keeps its existing account path and wire format while sharing
/// the DAV protocol implementation with generic WebDAV connections.
class NextcloudSyncTransport extends WebDavSyncTransport {
  NextcloudSyncTransport({
    required super.httpClient,
    required Uri server,
    required super.username,
    String? davUserId,
    required super.appPassword,
    required super.libraryId,
  }) : super(server: _accountRoot(server, davUserId ?? username));

  static Uri _accountRoot(Uri server, String userId) {
    final Uri root;
    try {
      root = WebDavSyncTransport.normalizeServer(server);
    } catch (_) {
      throw ArgumentError('Invalid Nextcloud connection');
    }
    if (userId.isEmpty ||
        userId == '.' ||
        userId == '..' ||
        userId.contains('/') ||
        userId.contains('\\')) {
      throw ArgumentError('Invalid Nextcloud user');
    }
    return root.replace(
      pathSegments: [
        ...root.pathSegments.where((part) => part.isNotEmpty),
        'remote.php',
        'dav',
        'files',
        userId,
      ],
    );
  }
}
