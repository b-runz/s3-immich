import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

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
    final name = p.basename(filename);
    final y = createdAt.year.toString().padLeft(4, '0');
    final m = createdAt.month.toString().padLeft(2, '0');
    final d = createdAt.day.toString().padLeft(2, '0');
    final path = '$y/$m/$d/$name';
    return prefix != null ? '$prefix/$path' : path;
  }

  String thumbnailKeyFor(String filename, DateTime createdAt) =>
      '.thumbs/${s3KeyFor(filename, createdAt)}';

  S3Config copyWith({
    String? endpoint,
    String? bucket,
    String? region,
    String? accessKey,
    String? secretKey,
    Object? prefix = _sentinel,
    bool? useSSL,
    bool? pathStyle,
  }) {
    return S3Config(
      endpoint: endpoint ?? this.endpoint,
      bucket: bucket ?? this.bucket,
      region: region ?? this.region,
      accessKey: accessKey ?? this.accessKey,
      secretKey: secretKey ?? this.secretKey,
      prefix: prefix == _sentinel ? this.prefix : prefix as String?,
      useSSL: useSSL ?? this.useSSL,
      pathStyle: pathStyle ?? this.pathStyle,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is S3Config &&
        other.endpoint == endpoint &&
        other.bucket == bucket &&
        other.region == region &&
        other.accessKey == accessKey &&
        other.secretKey == secretKey &&
        other.prefix == prefix &&
        other.useSSL == useSSL &&
        other.pathStyle == pathStyle;
  }

  @override
  int get hashCode {
    return Object.hash(
        endpoint, bucket, region, accessKey, secretKey, prefix, useSSL, pathStyle);
  }

  static const Object _sentinel = Object();
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
