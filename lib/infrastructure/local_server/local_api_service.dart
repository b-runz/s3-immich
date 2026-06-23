import 'package:openapi/api.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/local_server/local_api_client.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/s3/s3_service.dart';

class LocalApiService extends ApiService {
  final Drift _db;
  final S3Service _s3;

  LocalApiService(this._db, this._s3) {
    _injectLocalClient();
  }

  void _injectLocalClient() {
    final client = LocalApiClient(_db, _s3);
    authenticationApi = AuthenticationApi(client);
    oAuthApi = AuthenticationApi(client);
    usersApi = UsersApi(client);
    assetsApi = AssetsApi(client);
    syncApi = SyncApi(client);
    searchApi = SearchApi(client);
    albumsApi = AlbumsApi(client);
    partnersApi = PartnersApi(client);
    peopleApi = PeopleApi(client);
    memoriesApi = MemoriesApi(client);
    trashApi = TrashApi(client);
    serverInfoApi = ServerApi(client);
    sharedLinksApi = SharedLinksApi(client);
    activitiesApi = ActivitiesApi(client);
    tagsApi = TagsApi(client);
    stacksApi = StacksApi(client);
    sessionsApi = SessionsApi(client);
    downloadApi = DownloadApi(client);
    mapApi = MapApi(client);
    systemConfigApi = SystemConfigApi(client);
    viewApi = ViewsApi(client);
  }

  @override
  void setEndpoint(String endpoint) {
    // Re-inject local client so external setEndpoint calls never replace it
    _injectLocalClient();
  }
}
