import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class OnDeviceFaceDetector {
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      minFaceSize: 0.1,
    ),
  );

  Future<List<Rect>> detect(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    final faces = await _detector.processImage(inputImage);
    final meta = inputImage.metadata;
    if (meta == null) {
      return [];
    }
    final w = meta.size.width;
    final h = meta.size.height;
    if (w == 0 || h == 0) {
      return [];
    }
    return faces
        .map(
          (f) => Rect.fromLTRB(
            f.boundingBox.left / w,
            f.boundingBox.top / h,
            f.boundingBox.right / w,
            f.boundingBox.bottom / h,
          ),
        )
        .toList();
  }

  Future<void> close() => _detector.close();
}
