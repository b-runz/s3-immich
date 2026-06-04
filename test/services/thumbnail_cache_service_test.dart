import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:immich_mobile/services/thumbnail_cache.service.dart';
import 'package:immich_mobile/services/s3/s3_service.dart';

class MockS3Service extends Mock implements S3Service {}

void main() {
  late Directory tempDir;
  late MockS3Service s3;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('thumb_cache_test_');
    s3 = MockS3Service();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('ThumbnailCacheService', () {
    test('returns bytes from disk when file is already cached', () async {
      const s3Key = '.thumbs/2020/03/06/IMG_001.jpg';
      final cacheFile = File('${tempDir.path}/$s3Key');
      await cacheFile.parent.create(recursive: true);
      final expected = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      await cacheFile.writeAsBytes(expected);

      final svc = ThumbnailCacheService(
        cacheDir: tempDir,
        s3: s3,
        httpClient: MockClient((_) async => throw Exception('should not hit network')),
      );

      final result = await svc.getOrFetch(s3Key);
      expect(result, equals(expected));
      verifyNever(() => s3.presignGet(any()));
    });

    test('downloads from S3 and writes to disk on cache miss', () async {
      const s3Key = '.thumbs/2020/03/06/IMG_002.jpg';
      const fakePresignedUrl = 'https://s3.example.com/bucket/.thumbs/2020/03/06/IMG_002.jpg?X-Amz-Signature=abc';
      final fakeBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1]);

      when(() => s3.presignGet(s3Key)).thenAnswer((_) async => fakePresignedUrl);

      final svc = ThumbnailCacheService(
        cacheDir: tempDir,
        s3: s3,
        httpClient: MockClient((request) async {
          expect(request.url.toString(), fakePresignedUrl);
          return http.Response.bytes(fakeBytes, 200);
        }),
      );

      final result = await svc.getOrFetch(s3Key);
      expect(result, equals(fakeBytes));

      final cacheFile = File('${tempDir.path}/$s3Key');
      expect(await cacheFile.exists(), isTrue);
      expect(await cacheFile.readAsBytes(), equals(fakeBytes));
    });

    test('second call to same key reads from disk without hitting network', () async {
      const s3Key = '.thumbs/2020/03/06/IMG_003.jpg';
      const fakePresignedUrl = 'https://s3.example.com/presigned';
      final fakeBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      int networkHits = 0;

      when(() => s3.presignGet(s3Key)).thenAnswer((_) async => fakePresignedUrl);

      final svc = ThumbnailCacheService(
        cacheDir: tempDir,
        s3: s3,
        httpClient: MockClient((_) async {
          networkHits++;
          return http.Response.bytes(fakeBytes, 200);
        }),
      );

      await svc.getOrFetch(s3Key);
      await svc.getOrFetch(s3Key);

      expect(networkHits, 1);
    });

    test('throws on non-2xx HTTP response and does not cache', () async {
      const s3Key = '.thumbs/2020/03/06/IMG_004.jpg';
      const fakePresignedUrl = 'https://s3.example.com/presigned';

      when(() => s3.presignGet(s3Key)).thenAnswer((_) async => fakePresignedUrl);

      final svc = ThumbnailCacheService(
        cacheDir: tempDir,
        s3: s3,
        httpClient: MockClient((_) async => http.Response('Forbidden', 403)),
      );

      await expectLater(svc.getOrFetch(s3Key), throwsA(isA<http.ClientException>()));

      // File must NOT have been written to disk
      final cacheFile = File('${tempDir.path}/$s3Key');
      expect(await cacheFile.exists(), isFalse);
    });

    test('concurrent fetches for same key only hit network once', () async {
      const s3Key = '.thumbs/2020/03/06/IMG_005.jpg';
      const fakePresignedUrl = 'https://s3.example.com/presigned';
      final fakeBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      int networkHits = 0;

      when(() => s3.presignGet(s3Key)).thenAnswer((_) async => fakePresignedUrl);

      final svc = ThumbnailCacheService(
        cacheDir: tempDir,
        s3: s3,
        httpClient: MockClient((_) async {
          networkHits++;
          return http.Response.bytes(fakeBytes, 200);
        }),
      );

      // Fire two concurrent fetches for the same key
      final results = await Future.wait([svc.getOrFetch(s3Key), svc.getOrFetch(s3Key)]);
      expect(results[0], equals(fakeBytes));
      expect(results[1], equals(fakeBytes));
      expect(networkHits, 1);
    });
  });
}
