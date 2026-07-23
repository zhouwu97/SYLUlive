import 'dart:typed_data';

abstract interface class MediaPicker {
  Future<List<PickedMedia>> pickImages({int maxImages = 1});
}

class PickedMedia {
  final String name;
  final Uint8List bytes;
  final String? mimeType;

  const PickedMedia({
    required this.name,
    required this.bytes,
    this.mimeType,
  });
}
