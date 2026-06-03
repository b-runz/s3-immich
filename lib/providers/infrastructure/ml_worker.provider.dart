import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:s3mmich/infrastructure/ml/face_detector.dart';
import 'package:s3mmich/infrastructure/ml/image_labeler.dart';
import 'package:s3mmich/infrastructure/ml/ml_worker.service.dart';
import 'package:s3mmich/infrastructure/ml/ocr_ml_schema.dart';
import 'package:s3mmich/infrastructure/ml/text_recognizer.dart';
import 'package:s3mmich/infrastructure/repositories/asset_face_ml.repository.dart';
import 'package:s3mmich/infrastructure/repositories/asset_label.repository.dart';
import 'package:s3mmich/providers/infrastructure/db.provider.dart';

final mlWorkerServiceProvider = Provider<MlWorkerService>((ref) {
  final db = ref.watch(driftProvider);
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
  );
  ref.onDispose(() => service.dispose());
  return service;
});
