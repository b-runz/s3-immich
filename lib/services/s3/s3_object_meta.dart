class S3ObjectMeta {
  final String key;
  final String etag;
  final DateTime lastModified;
  final int size;

  const S3ObjectMeta({
    required this.key,
    required this.etag,
    required this.lastModified,
    required this.size,
  });
}

class S3Exception implements Exception {
  final String message;
  const S3Exception(this.message);
  @override
  String toString() => 'S3Exception: $message';
}
