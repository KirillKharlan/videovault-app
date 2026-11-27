import 'package:flutter/material.dart';

/// Иконки, из которых пользователь выбирает значок альбома. В БД хранится
/// ключ (строка), а не код иконки — так выбор не зависит от версии Flutter.
const Map<String, IconData> kAlbumIcons = {
  'folder': Icons.folder,
  'folder_special': Icons.folder_special,
  'star': Icons.star,
  'favorite': Icons.favorite,
  'music': Icons.music_note,
  'headphones': Icons.headphones,
  'movie': Icons.movie,
  'videocam': Icons.videocam,
  'games': Icons.sports_esports,
  'soccer': Icons.sports_soccer,
  'fitness': Icons.fitness_center,
  'school': Icons.school,
  'work': Icons.work,
  'flight': Icons.flight,
  'beach': Icons.beach_access,
  'food': Icons.restaurant,
  'cafe': Icons.local_cafe,
  'pets': Icons.pets,
  'car': Icons.directions_car,
  'home': Icons.home,
  'book': Icons.book,
  'idea': Icons.lightbulb,
  'camera': Icons.camera_alt,
  'palette': Icons.palette,
  'code': Icons.code,
  'science': Icons.science,
  'party': Icons.nightlife,
  'kids': Icons.child_care,
  'cake': Icons.cake,
  'globe': Icons.public,
};

/// Цвета значка альбома (ARGB). Первый — фирменный фиолетовый, он же по умолчанию.
const List<int> kAlbumColors = [
  0xFF7C5CFC, // фиолетовый (по умолчанию)
  0xFF4FC3F7, // голубой
  0xFF26A69A, // бирюзовый
  0xFF66BB6A, // зелёный
  0xFFFFCA28, // жёлтый
  0xFFFFA726, // оранжевый
  0xFFEF5350, // красный
  0xFFEC407A, // розовый
  0xFFAB47BC, // сиреневый
  0xFF90A4AE, // серый
];

const int kDefaultAlbumColor = 0xFF7C5CFC;

IconData albumIconData(String? key) => kAlbumIcons[key] ?? Icons.folder;

Color albumColor(int? argb) => Color(argb ?? kDefaultAlbumColor);
