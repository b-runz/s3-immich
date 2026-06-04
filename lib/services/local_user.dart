import 'package:immich_mobile/domain/models/user.model.dart';

const kLocalUserId = 'local-user';

final kLocalUser = UserDto(
  id: kLocalUserId,
  email: 'local@s3immich',
  name: 'My Device',
  isAdmin: false,
  profileChangedAt: DateTime.utc(2020),
);
