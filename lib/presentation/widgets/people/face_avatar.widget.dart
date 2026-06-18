import 'dart:math';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';

/// Circular avatar showing a person's face.
/// If `face_asset_id` starts with 'faces/' the stored thumbnail is already
/// a tight face crop — show it directly. Otherwise fall back to UI-level
/// crop using the bounding box (for older records that store the source photo key).
class FaceAvatarWidget extends StatelessWidget {
  final DriftPerson person;
  final double radius;

  const FaceAvatarWidget({super.key, required this.person, required this.radius});

  static const int _scale = 10000;
  static const double _padding = 1.5;

  @override
  Widget build(BuildContext context) {
    final thumbnailUrl = getFaceThumbnailUrl(person.faceAssetId);
    final diameter = radius * 2;

    Widget imageWidget = Image(
      image: RemoteImageProvider(url: thumbnailUrl),
      width: diameter,
      height: diameter,
      fit: BoxFit.fill,
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );

    // Pre-cropped thumbnails (face_asset_id = 'faces/{uuid}.jpg') need no transform
    final isCrop = person.faceAssetId?.startsWith('faces/') == true;
    if (!isCrop) {
      final x1 = person.faceBboxX1;
      final y1 = person.faceBboxY1;
      final x2 = person.faceBboxX2;
      final y2 = person.faceBboxY2;
      if (x1 != null && y1 != null && x2 != null && y2 != null) {
        final nx1 = x1 / _scale;
        final ny1 = y1 / _scale;
        final nx2 = x2 / _scale;
        final ny2 = y2 / _scale;
        final faceW = nx2 - nx1;
        final faceH = ny2 - ny1;
        final centerX = (nx1 + nx2) / 2;
        final centerY = (ny1 + ny2) / 2;
        final zoom = 1.0 / (max(faceW, faceH) * _padding);
        final tx = radius - centerX * diameter * zoom;
        final ty = radius - centerY * diameter * zoom;
        imageWidget = Transform.translate(
          offset: Offset(tx, ty),
          child: Transform.scale(
            scale: zoom,
            alignment: Alignment.topLeft,
            child: imageWidget,
          ),
        );
      }
    }

    return ClipOval(
      child: SizedBox(width: diameter, height: diameter, child: imageWidget),
    );
  }
}
