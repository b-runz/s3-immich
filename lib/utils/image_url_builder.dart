import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:openapi/api.dart';

// Returns the S3 object key for the asset's original file.
// RemoteImageRequest presigns this key before fetching.
String getOriginalUrlForRemoteId(final String id, {bool edited = true}) {
  return id;
}

// Returns the S3 object key for the asset's thumbnail.
// RemoteImageRequest presigns this key before fetching.
String getThumbnailUrlForRemoteId(
  final String id, {
  AssetMediaSize type = AssetMediaSize.thumbnail,
  bool edited = true,
  String? thumbhash,
}) {
  return '.thumbs/$id';
}

String getPlaybackUrlForRemoteId(final String id) {
  return '${Store.get(StoreKey.serverEndpoint)}/assets/$id/video/playback?';
}

String getFaceThumbnailUrl(final String? faceAssetId) {
  if (faceAssetId == null || faceAssetId.isEmpty) {
    return '';
  }
  return '.thumbs/$faceAssetId';
}
