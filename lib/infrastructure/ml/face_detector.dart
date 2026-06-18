import 'dart:io';
import 'dart:ui' as ui;
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
    if (faces.isEmpty) return [];

    // InputImage.fromFile does not populate .metadata on Android;
    // decode the image header separately to get pixel dimensions.
    final buffer = await ui.ImmutableBuffer.fromFilePath(imageFile.path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width.toDouble();
    final h = descriptor.height.toDouble();
    buffer.dispose();
    descriptor.dispose();

    if (w == 0 || h == 0) return [];

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
