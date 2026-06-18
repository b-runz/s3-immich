import 'dart:convert';

// TODO: Remove PersonDto once Isar is removed
class PersonDto {
  const PersonDto({
    required this.id,
    this.birthDate,
    required this.isHidden,
    required this.name,
    required this.thumbnailPath,
    this.updatedAt,
  });

  final String id;
  final DateTime? birthDate;
  final bool isHidden;
  final String name;
  final String thumbnailPath;
  final DateTime? updatedAt;

  @override
  String toString() {
    return 'Person(id: $id, birthDate: $birthDate, isHidden: $isHidden, name: $name, thumbnailPath: $thumbnailPath, updatedAt: $updatedAt)';
  }

  PersonDto copyWith({
    String? id,
    DateTime? birthDate,
    bool? isHidden,
    String? name,
    String? thumbnailPath,
    DateTime? updatedAt,
  }) {
    return PersonDto(
      id: id ?? this.id,
      birthDate: birthDate ?? this.birthDate,
      isHidden: isHidden ?? this.isHidden,
      name: name ?? this.name,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'birthDate': birthDate?.millisecondsSinceEpoch,
      'isHidden': isHidden,
      'name': name,
      'thumbnailPath': thumbnailPath,
      'updatedAt': updatedAt?.millisecondsSinceEpoch,
    };
  }

  factory PersonDto.fromMap(Map<String, dynamic> map) {
    return PersonDto(
      id: map['id'] as String,
      birthDate: map['birthDate'] != null ? DateTime.fromMillisecondsSinceEpoch(map['birthDate'] as int) : null,
      isHidden: map['isHidden'] as bool,
      name: map['name'] as String,
      thumbnailPath: map['thumbnailPath'] as String,
      updatedAt: map['updatedAt'] != null ? DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int) : null,
    );
  }

  String toJson() => json.encode(toMap());

  factory PersonDto.fromJson(String source) => PersonDto.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  bool operator ==(covariant PersonDto other) {
    if (identical(this, other)) {
      return true;
    }

    return other.id == id &&
        other.birthDate == birthDate &&
        other.isHidden == isHidden &&
        other.name == name &&
        other.thumbnailPath == thumbnailPath &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        birthDate.hashCode ^
        isHidden.hashCode ^
        name.hashCode ^
        thumbnailPath.hashCode ^
        updatedAt.hashCode;
  }
}

// Model for a person stored in the server
class DriftPerson {
  final String id;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String ownerId;
  final String name;
  final String? faceAssetId;
  final bool isFavorite;
  final bool isHidden;
  final String? color;
  final DateTime? birthDate;
  // Normalized bounding box (0–10000) for the thumbnail face, null if no face yet
  final int? faceBboxX1;
  final int? faceBboxY1;
  final int? faceBboxX2;
  final int? faceBboxY2;

  const DriftPerson({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.ownerId,
    required this.name,
    this.faceAssetId,
    required this.isFavorite,
    required this.isHidden,
    required this.color,
    this.birthDate,
    this.faceBboxX1,
    this.faceBboxY1,
    this.faceBboxX2,
    this.faceBboxY2,
  });

  DriftPerson copyWith({
    String? id,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? ownerId,
    String? name,
    String? faceAssetId,
    bool? isFavorite,
    bool? isHidden,
    String? color,
    DateTime? birthDate,
    int? faceBboxX1,
    int? faceBboxY1,
    int? faceBboxX2,
    int? faceBboxY2,
  }) {
    return DriftPerson(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      ownerId: ownerId ?? this.ownerId,
      name: name ?? this.name,
      faceAssetId: faceAssetId ?? this.faceAssetId,
      isFavorite: isFavorite ?? this.isFavorite,
      isHidden: isHidden ?? this.isHidden,
      color: color ?? this.color,
      birthDate: birthDate ?? this.birthDate,
      faceBboxX1: faceBboxX1 ?? this.faceBboxX1,
      faceBboxY1: faceBboxY1 ?? this.faceBboxY1,
      faceBboxX2: faceBboxX2 ?? this.faceBboxX2,
      faceBboxY2: faceBboxY2 ?? this.faceBboxY2,
    );
  }

  @override
  String toString() {
    return '''Person {
    id: $id,
    createdAt: $createdAt,
    updatedAt: $updatedAt,
    ownerId: $ownerId,
    name: $name,
    faceAssetId: ${faceAssetId ?? "<NA>"},
    isFavorite: $isFavorite,
    isHidden: $isHidden,
    color: ${color ?? "<NA>"},
    birthDate: ${birthDate ?? "<NA>"}
}''';
  }

  @override
  bool operator ==(covariant DriftPerson other) {
    if (identical(this, other)) {
      return true;
    }

    return other.id == id &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt &&
        other.ownerId == ownerId &&
        other.name == name &&
        other.faceAssetId == faceAssetId &&
        other.isFavorite == isFavorite &&
        other.isHidden == isHidden &&
        other.color == color &&
        other.birthDate == birthDate &&
        other.faceBboxX1 == faceBboxX1 &&
        other.faceBboxY1 == faceBboxY1 &&
        other.faceBboxX2 == faceBboxX2 &&
        other.faceBboxY2 == faceBboxY2;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        createdAt.hashCode ^
        updatedAt.hashCode ^
        ownerId.hashCode ^
        name.hashCode ^
        faceAssetId.hashCode ^
        isFavorite.hashCode ^
        isHidden.hashCode ^
        color.hashCode ^
        birthDate.hashCode ^
        faceBboxX1.hashCode ^
        faceBboxY1.hashCode ^
        faceBboxX2.hashCode ^
        faceBboxY2.hashCode;
  }
}
