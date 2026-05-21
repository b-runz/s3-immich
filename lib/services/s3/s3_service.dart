import 'dart:io';
import 'dart:typed_data';

import 'package:minio_new/minio.dart';
import 'package:s3mmich/services/s3/s3_config.dart';
import 'package:s3mmich/services/s3/s3_object_meta.dart';

/// Wraps the minio_new [Minio] client to provide S3 operations for S3mmich.
class S3Service {
  S3Service() : _client = null, _config = null;

  /// Constructor for testing — injects a pre-built client and config.
  S3Service.withClient(Minio client, S3Config config)
      : _client = client,
        _config = config;

  Minio? _client;
  S3Config? _config;

  /// Whether the service has been configured with valid credentials.
  bool get isConfigured => _client != null && _config != null;

  /// The current configuration, or null if not configured.
  S3Config? get currentConfig => _config;

  /// Apply [config], persist to secure storage, and create the Minio client.
  Future<void> configure(S3Config config) async {
    await config.save();
    _apply(config);
  }

  /// Restore configuration from FlutterSecureStorage (called on app start).
  Future<void> loadFromStorage() async {
    final config = await S3Config.load();
    if (config != null) {
      _apply(config);
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // S3 operations
  // ---------------------------------------------------------------------------

  /// Generate a pre-signed PUT URL for [s3Key] valid for [ttl].
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

  /// Upload [data] bytes to [s3Key].
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

  /// Download [s3Key] and return its bytes.
  Future<List<int>> getObject(String s3Key) async {
    final client = _requireClient();
    final stream = await client.getObject(_config!.bucket, s3Key);
    return stream.fold<List<int>>(
      [],
      (acc, chunk) => acc..addAll(chunk),
    );
  }

  /// Return metadata for [s3Key], or null if the object does not exist.
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
      if (e.error?.code == 'NoSuchKey' ||
          e.message?.contains('NoSuchKey') == true) {
        return null;
      }
      throw S3Exception('S3 error on headObject($s3Key): ${e.message}');
    } catch (e) {
      throw S3Exception('Unexpected error on headObject($s3Key): $e');
    }
  }

  /// Upload a file from [filePath] to [s3Key], inferring content type from
  /// the file extension when possible.
  Future<void> putFile(
    String s3Key,
    String filePath, {
    String contentType = 'application/octet-stream',
  }) async {
    final bytes = await File(filePath).readAsBytes();
    await putObject(s3Key, bytes, contentType: contentType);
  }

  /// List all objects under [prefix]. Returns [S3ObjectMeta] for each object.
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
