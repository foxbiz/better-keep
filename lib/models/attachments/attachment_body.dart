abstract class AttachmentBody {
  Map<String, dynamic> toJson();
  String toRawJson();
  bool get dirty;
  String get path;
  double get aspectRatio;
  String get previewPath;
  String get thumbnailPath;
  Future<void> save({bool force = false, String? password});
  Future<void> delete();
  Future<void> lock(String password);
  Future<void> unlock(String password);
  Future<void> load([String? password]);
  void dispose();
}
