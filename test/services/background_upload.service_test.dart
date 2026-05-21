import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../fixtures/asset.stub.dart';
import '../infrastructure/repository.mock.dart';
import '../mocks/asset_entity.mock.dart';
import '../repository.mocks.dart';

class MockS3Service extends Mock implements S3Service {}

const _testS3Config = S3Config(
  endpoint: 's3.test.example.com',
  bucket: 'test-bucket',
  region: 'us-east-1',
  accessKey: 'AKIATEST',
  secretKey: 'secrettest',
);

void main() {
  late BackgroundUploadService sut;
  late MockUploadRepository mockUploadRepository;
  late MockStorageRepository mockStorageRepository;
  late MockDriftLocalAssetRepository mockLocalAssetRepository;
  late MockDriftBackupRepository mockBackupRepository;
  late MockAssetMediaRepository mockAssetMediaRepository;
  late MockS3Service mockS3Service;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => 'test',
    );
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
    await SettingsRepository.ensureInitialized(db);

    await Store.put(StoreKey.deviceId, 'test-device-id');
  });

  setUp(() {
    mockUploadRepository = MockUploadRepository();
    mockStorageRepository = MockStorageRepository();
    mockLocalAssetRepository = MockDriftLocalAssetRepository();
    mockBackupRepository = MockDriftBackupRepository();
    mockAssetMediaRepository = MockAssetMediaRepository();
    mockS3Service = MockS3Service();

    when(() => mockS3Service.currentConfig).thenReturn(_testS3Config);
    when(() => mockS3Service.presignPut(any())).thenAnswer((_) async => 'https://s3.test.example.com/test-bucket/presigned?sig=abc');

    sut = BackgroundUploadService(
      mockUploadRepository,
      mockStorageRepository,
      mockLocalAssetRepository,
      mockBackupRepository,
      mockAssetMediaRepository,
      mockS3Service,
    );

    mockUploadRepository.onUploadStatus = (_) {};
    mockUploadRepository.onTaskProgress = (_) {};
  });

  tearDown(() {
    sut.dispose();
  });

  group('getUploadTask', () {
    test('should use original filename from AssetMediaRepository as displayName', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/file.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'OriginalPhoto.jpg');

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.displayName, equals('OriginalPhoto.jpg'));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });

    test('should fall back to asset.name when getOriginalFilename returns null', () async {
      final asset = LocalAssetStub.image2;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/file.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => null);

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.displayName, equals(asset.name));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });

    test('should set live photo displayName extension to match video file extension', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/file.mov');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => mockFile);
      when(
        () => mockAssetMediaRepository.getOriginalFilename(asset.id),
      ).thenAnswer((_) async => 'OriginalLivePhoto.HEIC');

      final task = await sut.getUploadTask(asset);
      expect(task, isNotNull);
      expect(task!.displayName, equals('OriginalLivePhoto.mov'));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });
  });

  group('getLivePhotoUploadTask', () {
    test('should use original filename as displayName', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/livephoto.heic');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(
        () => mockAssetMediaRepository.getOriginalFilename(asset.id),
      ).thenAnswer((_) async => 'OriginalLivePhoto.HEIC');

      final task = await sut.getLivePhotoUploadTask(asset, 'video-id-123');

      expect(task, isNotNull);
      expect(task!.displayName, equals('OriginalLivePhoto.HEIC'));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });

    test('should fall back to asset.name when getOriginalFilename returns null', () async {
      final asset = LocalAssetStub.image2;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/fallback.heic');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => null);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => null);

      final task = await sut.getLivePhotoUploadTask(asset, 'video-id-456');
      expect(task, isNull);
    });
  });

  group('S3 upload task', () {
    test('buildUploadTask uses PUT method and presigned URL', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/test.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'test.jpg');

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.httpRequestMethod, equals('PUT'));
      expect(task.url, contains('presigned'));
      expect(task.fields, isEmpty);
      verify(() => mockS3Service.presignPut(any())).called(1);
    });

    test('buildUploadTask presigns with date-keyed S3 path', () async {
      final asset = LocalAsset(
        id: 'asset-id',
        name: 'photo.jpg',
        type: AssetType.image,
        createdAt: DateTime(2025, 3, 15),
        updatedAt: DateTime(2025, 3, 15),
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/photo.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');

      await sut.getUploadTask(asset);

      final captured = verify(() => mockS3Service.presignPut(captureAny())).captured;
      expect(captured.first as String, equals('2025/03/15/photo.jpg'));
    });
  });
}
