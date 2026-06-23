import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/services/s3/s3_service.dart';
import 'package:immich_mobile/services/thumbnail_cache.service.dart';

class S3ThumbnailProvider extends ImageProvider<S3ThumbnailProvider> {
  final String s3Key;
  final S3Service s3Service;
  final double scale;

  const S3ThumbnailProvider({
    required this.s3Key,
    required this.s3Service,
    this.scale = 1.0,
  });

  @override
  Future<S3ThumbnailProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(S3ThumbnailProvider key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      informationCollector: () => [DiagnosticsProperty('S3 key', key.s3Key)],
    );
  }

  Future<ui.Codec> _loadAsync(S3ThumbnailProvider key, ImageDecoderCallback decode) async {
    final Uint8List bytes;
    final cache = ThumbnailCacheService.instance;
    if (cache != null) {
      bytes = await cache.getOrFetch(key.s3Key);
    } else {
      bytes = Uint8List.fromList(await key.s3Service.getObject(key.s3Key));
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is S3ThumbnailProvider && other.s3Key == s3Key && other.scale == scale;

  @override
  int get hashCode => Object.hash(s3Key, scale);
}
