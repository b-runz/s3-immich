part of 'image_request.dart';

class RemoteImageRequest extends ImageRequest {
  final String uri;

  RemoteImageRequest({required this.uri});

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) return null;

    if (uri.startsWith('.thumbs/')) {
      return _loadFromCache(scale);
    }
    return _loadFromNative(scale);
  }

  @override
  Future<ui.Codec?> loadCodec() async {
    if (_isCancelled) return null;

    if (uri.startsWith('.thumbs/')) {
      return _codecFromCache();
    }
    return _codecFromNative();
  }

  @override
  Future<void> _onCancelled() {
    return remoteImageApi.cancelRequest(requestId);
  }

  // --- thumbnail path (disk cache → Dart decoder) ---

  Future<ImageInfo?> _loadFromCache(double scale) async {
    final cache = ThumbnailCacheService.instance;
    if (cache == null) return null;

    final bytes = await cache.getOrFetch(uri);
    if (_isCancelled) return null;

    final frame = await _fromEncodedPlatformBytes(bytes);
    return frame == null ? null : ImageInfo(image: frame.image, scale: scale);
  }

  Future<ui.Codec?> _codecFromCache() async {
    final cache = ThumbnailCacheService.instance;
    if (cache == null) return null;

    final bytes = await cache.getOrFetch(uri);
    if (_isCancelled) return null;

    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    if (_isCancelled) {
      buffer.dispose();
      return null;
    }
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    buffer.dispose();
    if (_isCancelled) {
      descriptor.dispose();
      return null;
    }
    final codec = await descriptor.instantiateCodec();
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }
    return codec;
  }

  // --- original path (presign → native remoteImageApi) ---

  Future<ImageInfo?> _loadFromNative(double scale) async {
    final s3 = S3Service.global;
    if (s3 == null || !s3.isConfigured) return null;
    final presignedUrl = await s3.presignGet(uri);
    if (_isCancelled) return null;

    final info = await remoteImageApi.requestImage(presignedUrl, requestId: requestId, preferEncoded: false);
    final frame = switch (info) {
      {'pointer': int pointer, 'length': int length} => await _fromEncodedPlatformImage(pointer, length),
      {'pointer': int pointer, 'width': int width, 'height': int height, 'rowBytes': int rowBytes} =>
        await _fromDecodedPlatformImage(pointer, width, height, rowBytes),
      _ => null,
    };
    return frame == null ? null : ImageInfo(image: frame.image, scale: scale);
  }

  Future<ui.Codec?> _codecFromNative() async {
    final s3 = S3Service.global;
    if (s3 == null || !s3.isConfigured) return null;
    final presignedUrl = await s3.presignGet(uri);
    if (_isCancelled) return null;

    final info = await remoteImageApi.requestImage(presignedUrl, requestId: requestId, preferEncoded: true);
    if (info == null) return null;

    final (codec, _) = await _codecFromEncodedPlatformImage(info['pointer']!, info['length']!) ?? (null, null);
    return codec;
  }

  // --- helper: decode raw Dart bytes to a FrameInfo ---

  Future<ui.FrameInfo?> _fromEncodedPlatformBytes(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    if (_isCancelled) {
      buffer.dispose();
      return null;
    }
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    buffer.dispose();
    if (_isCancelled) {
      descriptor.dispose();
      return null;
    }
    final codec = await descriptor.instantiateCodec();
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }
    final frame = await codec.getNextFrame();
    descriptor.dispose();
    codec.dispose();
    if (_isCancelled) {
      frame.image.dispose();
      return null;
    }
    return frame;
  }
}
