import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:s3mmich/services/db_sync.service.dart';
import 'package:s3mmich/services/s3/s3_service.dart';
import 'package:s3mmich/services/s3/s3_object_meta.dart';

class MockS3Service extends Mock implements S3Service {}

void main() {
  late MockS3Service s3;
  late DbSyncService svc;

  setUp(() {
    s3 = MockS3Service();
    svc = DbSyncService(s3Service: s3, dbPath: '/tmp/test.db');
  });

  group('DbSyncService', () {
    test('push uploads db file to .meta/s3immich.db', () async {
      when(() => s3.putFile(any(), any())).thenAnswer((_) async {});
      await svc.push();
      verify(() => s3.putFile('.meta/s3immich.db', '/tmp/test.db')).called(1);
    });

    test('pull does nothing when S3 version matches local', () async {
      final sameTime = DateTime(2024, 1, 5, 12);
      when(() => s3.headObject('.meta/s3immich.db')).thenAnswer(
        (_) async => S3ObjectMeta(key: '.meta/s3immich.db', etag: 'abc', lastModified: sameTime, size: 1024),
      );
      svc.setLastSyncTime(sameTime);
      await svc.pull();
      verifyNever(() => s3.getObject(any()));
    });

    test('pull downloads when S3 is newer', () async {
      final newerTime = DateTime(2024, 1, 5, 13);
      when(() => s3.headObject('.meta/s3immich.db')).thenAnswer(
        (_) async => S3ObjectMeta(key: '.meta/s3immich.db', etag: 'abc', lastModified: newerTime, size: 1024),
      );
      when(() => s3.getObject('.meta/s3immich.db')).thenAnswer((_) async => [1, 2, 3]);
      svc.setLastSyncTime(DateTime(2024, 1, 5, 10));
      await svc.pull();
      verify(() => s3.getObject('.meta/s3immich.db')).called(1);
    });

    test('pull does nothing when remote db does not exist yet', () async {
      when(() => s3.headObject('.meta/s3immich.db')).thenAnswer((_) async => null);
      await svc.pull();
      verifyNever(() => s3.getObject(any()));
    });
  });
}
