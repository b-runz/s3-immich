import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/infrastructure/ml/face_detector.dart';
import 'package:immich_mobile/infrastructure/ml/image_labeler.dart';
import 'package:immich_mobile/infrastructure/ml/ml_worker.service.dart';
import 'package:immich_mobile/infrastructure/ml/ocr_ml_schema.dart';
import 'package:immich_mobile/infrastructure/ml/text_recognizer.dart';
import 'package:immich_mobile/infrastructure/repositories/asset_face_ml.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/asset_label.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/services/s3/s3_service_provider.dart';

final mlWorkerServiceProvider = Provider<MlWorkerService>((ref) {
  final db = ref.watch(driftProvider);
  final s3 = ref.watch(s3ServiceProvider);
  final faceRepo = AssetFaceMlRepository(db);
  final labelRepo = AssetLabelRepository(db);
  // ignore: discarded_futures
  OcrMlSchema.ensureSchema(db);
  final service = MlWorkerService(
    OnDeviceFaceDetector(),
    faceRepo,
    OnDeviceTextRecognizer(),
    OnDeviceImageLabeler(),
    labelRepo,
    db,
    s3,
  );
  ref.onDispose(() => service.dispose());
  return service;
});
