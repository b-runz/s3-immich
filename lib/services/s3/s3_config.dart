import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';

class S3Config {
  final String endpoint;   // hostname only: 's3.nl-ams.scw.cloud'
  final String bucket;
  final String region;
  final String accessKey;
  final String secretKey;
  final String? prefix;
  final bool useSSL;

  const S3Config({
    required this.endpoint,
    required this.bucket,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.prefix,
    this.useSSL = true,
  });

  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'bucket': bucket,
    'region': region,
    'accessKey': accessKey,
    'secretKey': secretKey,
    if (prefix != null) 'prefix': prefix,
    'useSSL': useSSL,
  };

  factory S3Config.fromJson(Map<String, dynamic> json) => S3Config(
    endpoint: json['endpoint'] as String,
    bucket: json['bucket'] as String,
    region: json['region'] as String,
    accessKey: json['accessKey'] as String,
    secretKey: json['secretKey'] as String,
    prefix: json['prefix'] as String?,
    useSSL: json['useSSL'] as bool? ?? true,
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
  }) {
    return S3Config(
      endpoint: endpoint ?? this.endpoint,
      bucket: bucket ?? this.bucket,
      region: region ?? this.region,
      accessKey: accessKey ?? this.accessKey,
      secretKey: secretKey ?? this.secretKey,
      prefix: prefix == _sentinel ? this.prefix : prefix as String?,
      useSSL: useSSL ?? this.useSSL,
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
        other.useSSL == useSSL;
  }

  @override
  int get hashCode {
    return Object.hash(
        endpoint, bucket, region, accessKey, secretKey, prefix, useSSL);
  }

  static const Object _sentinel = Object();
  static const _storageKey = 's3_config_v1';

  // encryptedSharedPreferences avoids per-entry Keystore keys, which some
  // Android OEMs silently invalidate after long inactivity or a lock-screen change.
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  // Legacy storage – kept only for one-time migration of previously saved credentials.
  static const _legacyStorage = FlutterSecureStorage();

  static Future<S3Config?> load() async {
    // 1. Primary: durable secure storage.
    try {
      final raw = await _storage.read(key: _storageKey);
      if (raw != null) {
        return S3Config.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {}

    // 2. Secondary: Drift DB copy (survives Keystore wipes; written on every save()).
    try {
      final json = StoreService.I.tryGet(StoreKey.s3ConfigJson);
      if (json != null) {
        final config = S3Config.fromJson(jsonDecode(json) as Map<String, dynamic>);
        // Best-effort re-populate primary storage; don't let a write failure
        // prevent us from returning the successfully-loaded config.
        try { await _storage.write(key: _storageKey, value: json); } catch (_) {}
        return config;
      }
    } catch (_) {}

    // 3. Migration: legacy default secure-storage from before this change.
    try {
      final legacyRaw = await _legacyStorage.read(key: _storageKey);
      if (legacyRaw != null) {
        final config = S3Config.fromJson(jsonDecode(legacyRaw) as Map<String, dynamic>);
        try {
          await config.save(); // writes to primary + Drift
          await _legacyStorage.delete(key: _storageKey);
        } catch (_) {}
        return config;
      }
    } catch (_) {}

    return null;
  }

  Future<void> save() async {
    final json = jsonEncode(toJson());
    // Write to both stores independently so a broken Keystore/EncryptedSharedPrefs
    // doesn't prevent the Drift backup from being written.
    try {
      await _storage.write(key: _storageKey, value: json);
    } catch (_) {}
    try {
      await StoreService.I.put(StoreKey.s3ConfigJson, json);
    } catch (_) {}
  }

  static Future<void> clear() async {
    try { await _storage.delete(key: _storageKey); } catch (_) {}
    try { await StoreService.I.delete(StoreKey.s3ConfigJson); } catch (_) {}
  }
}
