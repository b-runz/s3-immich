import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minio_new/minio.dart';
import 'package:minio_new/models.dart' as minio_models;
import 'package:mocktail/mocktail.dart';
import 'package:s3mmich/services/s3/s3_config.dart';
import 'package:s3mmich/services/s3/s3_object_meta.dart';
import 'package:s3mmich/services/s3/s3_service.dart';

class MockMinio extends Mock implements Minio {}

// Fallback values required by mocktail for typed matchers
class _FakeUint8ListStream extends Fake implements Stream<Uint8List> {}

const _testConfig = S3Config(
  endpoint: 's3.nl-ams.scw.cloud',
  bucket: 'test-bucket',
  region: 'nl-ams',
  accessKey: 'AKIAIOSFODNN7EXAMPLE',
  secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
);

void main() {
  late MockMinio mockMinio;
  late S3Service service;

  setUpAll(() {
    registerFallbackValue(_FakeUint8ListStream());
  });

  setUp(() {
    mockMinio = MockMinio();
    service = S3Service.withClient(mockMinio, _testConfig);
  });

  group('S3Service', () {
    group('isConfigured', () {
      test('returns false before configure is called', () {
        final unconfigured = S3Service();
        expect(unconfigured.isConfigured, isFalse);
      });

      test('returns true after withClient constructor', () {
        expect(service.isConfigured, isTrue);
      });

      test('currentConfig is null before configure', () {
        final unconfigured = S3Service();
        expect(unconfigured.currentConfig, isNull);
      });

      test('currentConfig returns config after withClient', () {
        expect(service.currentConfig, equals(_testConfig));
      });
    });

    group('presignPut', () {
      test('calls presignedPutObject and returns URL', () async {
        const expectedUrl =
            'https://s3.nl-ams.scw.cloud/test-bucket/photos/img.jpg?X-Amz-Signature=abc';

        when(
          () => mockMinio.presignedPutObject(
            'test-bucket',
            any(),
            expires: any(named: 'expires'),
          ),
        ).thenAnswer((_) async => expectedUrl);

        final url = await service.presignPut('photos/img.jpg');
        expect(url, expectedUrl);

        verify(
          () => mockMinio.presignedPutObject(
            'test-bucket',
            'photos/img.jpg',
            expires: any(named: 'expires'),
          ),
        ).called(1);
      });

      test('passes correct ttl as seconds', () async {
        when(
          () => mockMinio.presignedPutObject(
            any(),
            any(),
            expires: any(named: 'expires'),
          ),
        ).thenAnswer((_) async => 'https://example.com/presigned');

        await service.presignPut('key.jpg', ttl: const Duration(hours: 2));

        final captured = verify(
          () => mockMinio.presignedPutObject(
            any(),
            any(),
            expires: captureAny(named: 'expires'),
          ),
        ).captured;

        expect(captured.first, 7200); // 2 hours in seconds
      });
    });

    group('putObject', () {
      test('calls minio putObject with correct bucket and key', () async {
        when(
          () => mockMinio.putObject(
            any(),
            any(),
            any(),
            size: any(named: 'size'),
            metadata: any(named: 'metadata'),
          ),
        ).thenAnswer((_) async => 'etag-value');

        final data = [1, 2, 3, 4, 5];
        await service.putObject('photos/img.jpg', data);

        verify(
          () => mockMinio.putObject(
            'test-bucket',
            'photos/img.jpg',
            any(),
            size: 5,
            metadata: any(named: 'metadata'),
          ),
        ).called(1);
      });

      test('passes content type in metadata map', () async {
        when(
          () => mockMinio.putObject(
            any(),
            any(),
            any(),
            size: any(named: 'size'),
            metadata: any(named: 'metadata'),
          ),
        ).thenAnswer((_) async => 'etag-value');

        await service.putObject(
          'photos/img.jpg',
          [1, 2, 3],
          contentType: 'image/jpeg',
        );

        final captured = verify(
          () => mockMinio.putObject(
            any(),
            any(),
            any(),
            size: any(named: 'size'),
            metadata: captureAny(named: 'metadata'),
          ),
        ).captured;

        final metadata = captured.first as Map<String, String>;
        expect(metadata['content-type'], 'image/jpeg');
      });
    });

    group('getObject', () {
      test('returns bytes from MinioByteStream', () async {
        final bytes = Uint8List.fromList([10, 20, 30, 40]);
        final stream = MinioByteStream.fromStream(
          stream: Stream.value(bytes),
          contentLength: bytes.length,
        );

        when(() => mockMinio.getObject(any(), any()))
            .thenAnswer((_) async => stream);

        final result = await service.getObject('photos/img.jpg');
        expect(result, equals([10, 20, 30, 40]));
      });
    });

    group('headObject', () {
      test('returns null when NoSuchKey error is thrown', () async {
        final s3Error = MinioS3Error('NoSuchKey')
          ..error = (minio_models.Error('NoSuchKey', null, null, null)
            ..code = 'NoSuchKey');

        when(() => mockMinio.statObject(any(), any()))
            .thenThrow(s3Error);

        final result = await service.headObject('nonexistent/key.jpg');
        expect(result, isNull);
      });

      test('maps StatObjectResult to S3ObjectMeta', () async {
        final lastModified = DateTime(2024, 1, 5);
        final stat = minio_models.StatObjectResult(
          size: 4096,
          etag: '"abc123"',
          lastModified: lastModified,
        );

        when(() => mockMinio.statObject(any(), any()))
            .thenAnswer((_) async => stat);

        final result = await service.headObject('photos/img.jpg');

        expect(result, isNotNull);
        expect(result!.key, 'photos/img.jpg');
        expect(result.etag, '"abc123"');
        expect(result.size, 4096);
        expect(result.lastModified, lastModified);
      });

      test('rethrows non-NoSuchKey error as S3Exception', () async {
        final s3Error = MinioS3Error('AccessDenied')
          ..error = (minio_models.Error('AccessDenied', null, null, null)
            ..code = 'AccessDenied');

        when(() => mockMinio.statObject(any(), any()))
            .thenThrow(s3Error);

        expect(
          () => service.headObject('photos/img.jpg'),
          throwsA(isA<S3Exception>()),
        );
      });
    });

    group('listPrefix', () {
      test('returns S3ObjectMeta list from listAllObjectsV2', () async {
        final objects = [
          minio_models.Object(
            '"etag1"',
            'photos/2024/01/a.jpg',
            DateTime(2024, 1, 1),
            null,
            1024,
            null,
          ),
          minio_models.Object(
            '"etag2"',
            'photos/2024/01/b.jpg',
            DateTime(2024, 1, 2),
            null,
            2048,
            null,
          ),
        ];
        final result = minio_models.ListObjectsResult(
          objects: objects,
          prefixes: [],
        );

        when(
          () => mockMinio.listAllObjectsV2(
            'test-bucket',
            prefix: any(named: 'prefix'),
            recursive: any(named: 'recursive'),
          ),
        ).thenAnswer((_) async => result);

        final metas = await service.listPrefix('photos/2024/01/');
        expect(metas.length, 2);
        expect(metas[0].key, 'photos/2024/01/a.jpg');
        expect(metas[0].etag, '"etag1"');
        expect(metas[0].size, 1024);
        expect(metas[1].key, 'photos/2024/01/b.jpg');
        expect(metas[1].size, 2048);
      });

      test('skips objects with null key', () async {
        final objects = [
          minio_models.Object('"etag1"', null, DateTime(2024, 1, 1), null, 1024, null),
          minio_models.Object(
            '"etag2"',
            'photos/img.jpg',
            DateTime(2024, 1, 2),
            null,
            2048,
            null,
          ),
        ];
        final result = minio_models.ListObjectsResult(
          objects: objects,
          prefixes: [],
        );

        when(
          () => mockMinio.listAllObjectsV2(
            any(),
            prefix: any(named: 'prefix'),
            recursive: any(named: 'recursive'),
          ),
        ).thenAnswer((_) async => result);

        final metas = await service.listPrefix('photos/');
        expect(metas.length, 1);
        expect(metas[0].key, 'photos/img.jpg');
      });
    });
  });
}
