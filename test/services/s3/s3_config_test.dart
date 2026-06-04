import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/services/s3/s3_config.dart';

void main() {
  group('S3Config', () {
    test('round-trips through JSON preserving all fields', () {
      const config = S3Config(
        endpoint: 's3.nl-ams.scw.cloud',
        bucket: 'my-photos',
        region: 'nl-ams',
        accessKey: 'AKIAIOSFODNN7EXAMPLE',
        secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
        prefix: 'photos',
        useSSL: true,
      );
      final restored = S3Config.fromJson(config.toJson());
      expect(restored.endpoint, config.endpoint);
      expect(restored.bucket, config.bucket);
      expect(restored.region, config.region);
      expect(restored.accessKey, config.accessKey);
      expect(restored.secretKey, config.secretKey);
      expect(restored.prefix, config.prefix);
      expect(restored.useSSL, config.useSSL);
    });

    test('handles null prefix and defaults', () {
      const config = S3Config(
        endpoint: 'minio.local',
        bucket: 'my-photos',
        region: 'us-east-1',
        accessKey: 'AKIA',
        secretKey: 'secret',
      );
      final restored = S3Config.fromJson(config.toJson());
      expect(restored.prefix, isNull);
      expect(restored.useSSL, isTrue);
    });

    test('s3KeyFor generates date-based path with prefix', () {
      const config = S3Config(
        endpoint: 's3.nl-ams.scw.cloud',
        bucket: 'photos',
        region: 'nl-ams',
        accessKey: 'AKIA',
        secretKey: 'secret',
        prefix: 'mydevice',
      );
      final key = config.s3KeyFor('IMG_1234.JPG', DateTime(2024, 1, 5));
      expect(key, 'mydevice/2024/01/05/IMG_1234.JPG');
    });

    test('s3KeyFor without prefix', () {
      const config = S3Config(
        endpoint: 's3.nl-ams.scw.cloud',
        bucket: 'photos',
        region: 'nl-ams',
        accessKey: 'AKIA',
        secretKey: 'secret',
      );
      final key = config.s3KeyFor('IMG_1234.JPG', DateTime(2024, 1, 5));
      expect(key, '2024/01/05/IMG_1234.JPG');
    });

    test('thumbnailKeyFor prepends .thumbs/ prefix', () {
      const config = S3Config(
        endpoint: 's3.nl-ams.scw.cloud',
        bucket: 'photos',
        region: 'nl-ams',
        accessKey: 'AKIA',
        secretKey: 'secret',
        prefix: 'mydevice',
      );
      final key = config.thumbnailKeyFor('IMG_1234.JPG', DateTime(2024, 1, 5));
      expect(key, '.thumbs/mydevice/2024/01/05/IMG_1234.JPG');
    });

    test('round-trips non-default booleans', () {
      const config = S3Config(
        endpoint: 'minio.local',
        bucket: 'bucket',
        region: 'us-east-1',
        accessKey: 'AKIA',
        secretKey: 'secret',
        useSSL: false,
      );
      final restored = S3Config.fromJson(config.toJson());
      expect(restored.useSSL, isFalse);
    });

    test('equality and hashCode work', () {
      const a = S3Config(
        endpoint: 's3.nl-ams.scw.cloud', bucket: 'b', region: 'r',
        accessKey: 'k', secretKey: 's',
      );
      const b = S3Config(
        endpoint: 's3.nl-ams.scw.cloud', bucket: 'b', region: 'r',
        accessKey: 'k', secretKey: 's',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
