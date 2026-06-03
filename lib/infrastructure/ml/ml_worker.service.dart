import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:s3mmich/infrastructure/ml/face_detector.dart';
import 'package:s3mmich/infrastructure/ml/image_labeler.dart';
import 'package:s3mmich/infrastructure/ml/ocr_ml_schema.dart';
import 'package:s3mmich/infrastructure/ml/text_recognizer.dart';
import 'package:s3mmich/infrastructure/repositories/asset_face_ml.repository.dart';
import 'package:s3mmich/infrastructure/repositories/asset_label.repository.dart';
import 'package:s3mmich/infrastructure/repositories/db.repository.dart';

class MlProgress {
  final String assetId;
  final int facesFound;
  final int labelsFound;
  final int ocrChars;

  const MlProgress({
    required this.assetId,
    required this.facesFound,
    required this.labelsFound,
    required this.ocrChars,
  });
}

/// Background ML pipeline. All processing is on-device — no network required.
class MlWorkerService {
  final OnDeviceFaceDetector _faceDetector;
  final AssetFaceMlRepository _faceRepo;
  final OnDeviceTextRecognizer _textRecognizer;
  final OnDeviceImageLabeler _imageLabeler;
  final AssetLabelRepository _labelRepo;
  final Drift _db;
  final Logger _log = Logger('MlWorkerService');

  @visibleForTesting
  final List<(String assetId, File imageFile)> queue = [];

  bool _running = false;
  final _progressController = StreamController<MlProgress>.broadcast();

  MlWorkerService(
    this._faceDetector,
    this._faceRepo,
    this._textRecognizer,
    this._imageLabeler,
    this._labelRepo,
    this._db,
  );

  Stream<MlProgress> get progress => _progressController.stream;

  void enqueue(String assetId, File imageFile) {
    queue.add((assetId, imageFile));
  }

  /// Starts draining the queue in the background. No-op if already running.
  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    unawaited(_drain());
  }

  Future<void> stop() async {
    _running = false;
  }

  Future<void> _drain() async {
    while (_running && queue.isNotEmpty) {
      final (assetId, imageFile) = queue.removeAt(0);
      int facesFound = 0, labelsFound = 0, ocrChars = 0;

      try {
        if (!await _faceRepo.isFaceProcessed(assetId)) {
          final faces = await _faceDetector.detect(imageFile);
          for (final bbox in faces) {
            await _faceRepo.insertFace(assetId: assetId, normBoundingBox: bbox);
          }
          await _faceRepo.markFaceProcessed(assetId);
          facesFound = faces.length;
        }
      } catch (e, st) {
        _log.warning('Face detection failed for $assetId', e, st);
      }

      try {
        if (!await _isOcrProcessed(assetId)) {
          final text = await _textRecognizer.recognize(imageFile);
          await OcrMlSchema.writeOcrText(_db, assetId, text);
          ocrChars = text.length;
        }
      } catch (e, st) {
        _log.warning('OCR failed for $assetId', e, st);
      }

      try {
        if (!await _labelRepo.isLabelsProcessed(assetId)) {
          final labels = await _imageLabeler.label(imageFile);
          await _labelRepo.replaceLabels(assetId, labels);
          labelsFound = labels.length;
        }
      } catch (e, st) {
        _log.warning('Image labeling failed for $assetId', e, st);
      }

      _progressController.add(MlProgress(
        assetId: assetId,
        facesFound: facesFound,
        labelsFound: labelsFound,
        ocrChars: ocrChars,
      ));
    }
    _running = false;
  }

  Future<bool> _isOcrProcessed(String assetId) async {
    final rows = await _db.customSelect(
      'SELECT ocr_processed FROM local_asset_entity WHERE id = ?',
      variables: [Variable.withString(assetId)],
    ).get();
    return rows.isNotEmpty && (rows.first.data['ocr_processed'] as int) == 1;
  }

  Future<void> dispose() async {
    _running = false;
    await _faceDetector.close();
    await _textRecognizer.close();
    await _imageLabeler.close();
    await _progressController.close();
  }
}
