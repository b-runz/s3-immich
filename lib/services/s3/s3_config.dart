import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class S3Config {
  final String endpoint;   // hostname only: 's3.nl-ams.scw.cloud'
  final String bucket;
  final String region;
  final String accessKey;
  final String secretKey;
  final String? prefix;
  final bool useSSL;       // default true
  final bool pathStyle;    // true for self-hosted MinIO; false for hosted providers

  const S3Config({
    required this.endpoint,
    required this.bucket,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.prefix,
    this.useSSL = true,
    this.pathStyle = false,
  });

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'bucket': bucket,
    'region': region,
    'accessKey': accessKey,
    'secretKey': secretKey,
    if (prefix != null) 'prefix': prefix,
    'useSSL': useSSL,
    'pathStyle': pathStyle,
  };

  factory S3Config.fromJson(Map<String, dynamic> json) => S3Config(
    endpoint: json['endpoint'] as String,
    bucket: json['bucket'] as String,
    region: json['region'] as String,
    accessKey: json['accessKey'] as String,
    secretKey: json['secretKey'] as String,
    prefix: json['prefix'] as String?,
    useSSL: json['useSSL'] as bool? ?? true,
    pathStyle: json['pathStyle'] as bool? ?? false,
  );

  String s3KeyFor(String filename, DateTime createdAt) {
    final y = createdAt.year.toString().padLeft(4, '0');
    final m = createdAt.month.toString().padLeft(2, '0');
    final d = createdAt.day.toString().padLeft(2, '0');
    final path = '$y/$m/$d/$filename';
    return prefix != null ? '$prefix/$path' : path;
  }

  String thumbnailKeyFor(String filename, DateTime createdAt) =>
      '.thumbs/${s3KeyFor(filename, createdAt)}';

  static const _storageKey = 's3_config_v1';
  static const _storage = FlutterSecureStorage();

  static Future<S3Config?> load() async {
    final raw = await _storage.read(key: _storageKey);
    if (raw == null) return null;
    return S3Config.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save() =>
      _storage.write(key: _storageKey, value: jsonEncode(toJson()));

  static Future<void> clear() => _storage.delete(key: _storageKey);
}
