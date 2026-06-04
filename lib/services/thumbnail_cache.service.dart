import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/services/s3/s3_service.dart';

class ThumbnailCacheService {
  static ThumbnailCacheService? instance;

  final Directory _cacheDir;
  final S3Service _s3;
  final http.Client _httpClient;

  ThumbnailCacheService({
    required Directory cacheDir,
    required S3Service s3,
    http.Client? httpClient,
  })  : _cacheDir = cacheDir,
        _s3 = s3,
        _httpClient = httpClient ?? http.Client();

  Future<Uint8List> getOrFetch(String s3Key) async {
    final file = File('${_cacheDir.path}/$s3Key');
    if (await file.exists()) {
      return file.readAsBytes();
    }
    final url = await _s3.presignGet(s3Key);
    final response = await _httpClient.get(Uri.parse(url));
    final bytes = response.bodyBytes;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return bytes;
  }
}
