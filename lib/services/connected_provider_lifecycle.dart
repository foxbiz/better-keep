Future<void> unlinkConnectedProvider({
  required String providerId,
  required Iterable<String> firebaseProviderIds,
  required Future<void> Function() removeMetadata,
  required void Function() clearCachedProvider,
  required Future<void> Function(String providerId) unlinkFirebaseProvider,
}) async {
  await removeMetadata();
  clearCachedProvider();

  if (firebaseProviderIds.contains(providerId)) {
    await unlinkFirebaseProvider(providerId);
  }
}
