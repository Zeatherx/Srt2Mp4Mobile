/// A public destination and its playable URI. Android uses a MediaStore URI
/// because public files cannot always be opened through a raw file path.
class ExportedVideo {
  const ExportedVideo({
    required this.path,
    required this.playbackUri,
    required this.size,
    this.isPublic = false,
    this.storageNotice,
  });
  final String path;
  final Uri playbackUri;
  final int size;
  final bool isPublic;
  final String? storageNotice;
}
