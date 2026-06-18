import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:immich_mobile/infrastructure/ml/face_detector.dart';
import 'package:immich_mobile/infrastructure/ml/image_labeler.dart';
import 'package:immich_mobile/infrastructure/ml/ocr_ml_schema.dart';
import 'package:immich_mobile/infrastructure/ml/text_recognizer.dart';
import 'package:immich_mobile/infrastructure/repositories/asset_face_ml.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/asset_label.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/services/s3/s3_service.dart';
import 'package:uuid/uuid.dart';

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
  final S3Service _s3;
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
    this._s3,
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
          final remoteId = await _faceRepo.getRemoteIdForLocal(assetId);
          if (remoteId != null) {
            final faces = await _faceDetector.detect(imageFile);
            for (final bbox in faces) {
              final personId = const Uuid().v4();
              final cropKey = 'faces/$personId.jpg';
              String? uploadedCropKey;
              try {
                final cropBytes = await _cropFace(imageFile, bbox);
                if (cropBytes != null) {
                  await _s3.putObject('.thumbs/$cropKey', cropBytes, contentType: 'image/jpeg');
                  uploadedCropKey = cropKey;
                }
              } catch (e) {
                _log.warning('Face crop upload failed for $personId', e);
              }
              final faceId = await _faceRepo.insertFace(assetId: remoteId, normBoundingBox: bbox);
              await _faceRepo.createPersonForFace(
                faceId: faceId,
                remoteAssetId: remoteId,
                faceThumbnailKey: uploadedCropKey,
                personId: personId,
              );
            }
            await _faceRepo.markFaceProcessed(assetId);
            facesFound = faces.length;
          }
          // If remoteId is null the photo isn't uploaded yet — leave face_processed=0
          // so the upload service re-enqueues it after backup completes.
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

  /// Crops the image to the face region (with padding) and encodes as JPEG.
  /// Returns null if decoding or encoding fails.
  Future<Uint8List?> _cropFace(File imageFile, ui.Rect normBbox) async {
    ui.Image? uiImage;
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(imageFile.path);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      uiImage = frame.image;
      buffer.dispose();
      descriptor.dispose();
      codec.dispose();

      final iw = uiImage.width.toDouble();
      final ih = uiImage.height.toDouble();

      // Square crop centred on face with 20% padding — avoids aspect distortion
      // when drawn into the 256×256 output square.
      final cx = (normBbox.left + normBbox.right) / 2;
      final cy = (normBbox.top + normBbox.bottom) / 2;
      final half = max(normBbox.width, normBbox.height) / 2 * 1.4;
      final src = ui.Rect.fromLTRB(
        ((cx - half) * iw).clamp(0.0, iw),
        ((cy - half) * ih).clamp(0.0, ih),
        ((cx + half) * iw).clamp(0.0, iw),
        ((cy + half) * ih).clamp(0.0, ih),
      );

      const outSize = 256.0;
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(uiImage, src, const ui.Rect.fromLTWH(0, 0, outSize, outSize), ui.Paint());
      final picture = recorder.endRecording();
      final cropped = await picture.toImage(256, 256);
      uiImage.dispose();
      uiImage = null;

      final rgba = await cropped.toByteData(format: ui.ImageByteFormat.rawRgba);
      cropped.dispose();
      if (rgba == null) {
        return null;
      }

      final decoded = img.Image.fromBytes(
        width: 256,
        height: 256,
        bytes: rgba.buffer,
        numChannels: 4,
      );
      return Uint8List.fromList(img.encodeJpg(decoded, quality: 85));
    } catch (e) {
      uiImage?.dispose();
      _log.warning('Face crop failed', e);
      return null;
    }
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
