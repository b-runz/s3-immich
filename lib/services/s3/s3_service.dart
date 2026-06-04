import 'dart:io';
import 'dart:typed_data';

import 'package:minio_new/minio.dart';
import 'package:immich_mobile/services/s3/s3_config.dart';
import 'package:immich_mobile/services/s3/s3_object_meta.dart';

class S3Service {
  S3Service() : _client = null, _config = null;

  S3Service.withClient(Minio client, S3Config config)
      : _client = client,
        _config = config;

  Minio? _client;
  S3Config? _config;

  bool get isConfigured => _client != null && _config != null;

  S3Config? get currentConfig => _config;

  Future<void> configure(S3Config config) async {
    await config.save();
    _apply(config);
  }

  Future<void> loadFromStorage() async {
    final config = await S3Config.load();
    if (config != null) {
      _apply(config);
    }
  }

  void _apply(S3Config config) {
    _config = config;
    _client = Minio(
      endPoint: config.endpoint,
      accessKey: config.accessKey,
      secretKey: config.secretKey,
      useSSL: config.useSSL,
      region: config.region,
    );
  }

  Minio _requireClient() {
    if (_client == null || _config == null) {
      throw const S3Exception('S3Service is not configured. Call configure() first.');
    }
    return _client!;
  }

  Future<String> presignPut(
    String s3Key, {
    Duration ttl = const Duration(hours: 1),
  }) async {
    final client = _requireClient();
    return client.presignedPutObject(
      _config!.bucket,
      s3Key,
      expires: ttl.inSeconds,
    );
  }

  Future<void> putObject(
    String s3Key,
    List<int> data, {
    String contentType = 'application/octet-stream',
  }) async {
    final client = _requireClient();
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    await client.putObject(
      _config!.bucket,
      s3Key,
      Stream.value(bytes),
      size: bytes.length,
      metadata: {'content-type': contentType},
    );
  }

  Future<List<int>> getObject(String s3Key) async {
    final client = _requireClient();
    final stream = await client.getObject(_config!.bucket, s3Key);
    return stream.fold<List<int>>(
      [],
      (acc, chunk) => acc..addAll(chunk),
    );
  }

  Future<S3ObjectMeta?> headObject(String s3Key) async {
    final client = _requireClient();
    try {
      final stat = await client.statObject(_config!.bucket, s3Key);
      return S3ObjectMeta(
        key: s3Key,
        etag: stat.etag ?? '',
        lastModified: stat.lastModified ?? DateTime.fromMillisecondsSinceEpoch(0),
        size: stat.size ?? 0,
      );
    } on MinioS3Error catch (e) {
      final status = e.response?.statusCode;
      final code = e.error?.code;
      if (status == 404 || code == 'NoSuchKey' || code == 'NoSuchBucket') {
        return null;
      }
      throw S3Exception('S3 error on headObject($s3Key): ${e.message}');
    } catch (e) {
      throw S3Exception('Unexpected error on headObject($s3Key): $e');
    }
  }

  Future<void> putFile(
    String s3Key,
    String filePath, {
    String contentType = 'application/octet-stream',
  }) async {
    final bytes = await File(filePath).readAsBytes();
    await putObject(s3Key, bytes, contentType: contentType);
  }

  Future<List<S3ObjectMeta>> listPrefix(String prefix) async {
    final client = _requireClient();
    final result = await client.listAllObjectsV2(
      _config!.bucket,
      prefix: prefix,
      recursive: true,
    );
    final metas = <S3ObjectMeta>[];
    for (final obj in result.objects) {
      final key = obj.key;
      if (key == null) {
        continue;
      }
      metas.add(S3ObjectMeta(
        key: key,
        etag: obj.eTag ?? '',
        lastModified: obj.lastModified ?? DateTime.fromMillisecondsSinceEpoch(0),
        size: obj.size ?? 0,
      ));
    }
    return metas;
  }
}
