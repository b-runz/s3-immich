import 'dart:io';
import 'package:flutter/widgets.dart' show Rect;
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

enum LabelSource { imageLabeler, objectDetector, custom }

class AssetLabel {
  final String label;
  final double confidence;
  final LabelSource source;
  final Rect? boundingBox;

  const AssetLabel({
    required this.label,
    required this.confidence,
    required this.source,
    this.boundingBox,
  });
}

class OnDeviceImageLabeler {
  final ImageLabeler _labeler = ImageLabeler(
    options: ImageLabelerOptions(confidenceThreshold: 0.6),
  );
  final ObjectDetector _detector = ObjectDetector(
    options: ObjectDetectorOptions(
      mode: DetectionMode.single,
      classifyObjects: true,
      multipleObjects: true,
    ),
  );

  Future<List<AssetLabel>> label(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);

    final results = <String, AssetLabel>{};

    // Scene labels
    final sceneLabels = await _labeler.processImage(inputImage);
    for (final l in sceneLabels) {
      results[l.label.toLowerCase()] = AssetLabel(
        label: l.label,
        confidence: l.confidence,
        source: LabelSource.imageLabeler,
      );
    }

    // Object detection — keep higher confidence if duplicate
    final objects = await _detector.processImage(inputImage);
    final meta = inputImage.metadata;
    for (final obj in objects) {
      for (final lbl in obj.labels) {
        final key = lbl.text.toLowerCase();
        Rect? bbox;
        if (meta != null && meta.size.width > 0 && meta.size.height > 0) {
          final w = meta.size.width;
          final h = meta.size.height;
          final bb = obj.boundingBox;
          bbox = Rect.fromLTRB(bb.left / w, bb.top / h, bb.right / w, bb.bottom / h);
        }
        final candidate = AssetLabel(
          label: lbl.text,
          confidence: lbl.confidence,
          source: LabelSource.objectDetector,
          boundingBox: bbox,
        );
        if (!results.containsKey(key) || results[key]!.confidence < lbl.confidence) {
          results[key] = candidate;
        }
      }
    }

    return results.values.toList()..sort((a, b) => b.confidence.compareTo(a.confidence));
  }

  Future<void> close() async {
    await _labeler.close();
    await _detector.close();
  }
}
