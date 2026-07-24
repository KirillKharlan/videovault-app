import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as vt;
import '../models/database.dart';

/// Импорт видео из галереи телефона в библиотеку приложения.
class GalleryImportService {
  final _picker = ImagePicker();
  final _db = AppDatabase();

  /// Возвращает Video если пользователь выбрал файл, иначе null (отмена).
  Future<Video?> importFromGallery({String? customTitle, int? albumId}) async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return null;

    final srcFile = File(picked.path);
    final videosDir = await _videosDir();
    final originalName = picked.name.isNotEmpty ? picked.name : 'imported_video.mp4';
    final ext = originalName.contains('.') ? originalName.split('.').last : 'mp4';

    final title = (customTitle != null && customTitle.trim().isNotEmpty)
        ? customTitle.trim()
        : originalName.replaceAll('.$ext', '');

    final safeName = '${_sanitize(title)}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final destPath = '${videosDir.path}/$safeName';
    await srcFile.copy(destPath);

    final fileSize = await File(destPath).length();

    // Длительность — коротко инициализируем плеер чтобы прочитать metadata
    int duration = 0;
    try {
      final ctrl = VideoPlayerController.file(File(destPath));
      await ctrl.initialize();
      duration = ctrl.value.duration.inSeconds;
      await ctrl.dispose();
    } catch (_) {
      // Не критично если не удалось — просто останется 0
    }

    // Миниатюра — генерируем из самого видео (нет YouTube-превью для локальных)
    String? thumbPath;
    try {
      final thumbsDir = await _thumbsDir();
      thumbPath = await vt.VideoThumbnail.thumbnailFile(
        video: destPath,
        thumbnailPath: thumbsDir.path,
        imageFormat: vt.ImageFormat.JPEG,
        maxWidth: 400,
        quality: 75,
      );
    } catch (_) {
      thumbPath = null;
    }

    final video = Video(
      title: title,
      filePath: destPath,
      thumbnailPath: thumbPath,
      sourceUrl: null,
      platform: 'gallery',
      duration: duration,
      fileSize: fileSize,
      albumId: albumId,
    );

    final id = await _db.insertVideo(video);
    return video.copyWith(id: id);
  }

  Future<Directory> _videosDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory('${base.path}/videos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _thumbsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory('${base.path}/thumbs');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _sanitize(String name) {
    final clean = name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return clean.length > 60 ? clean.substring(0, 60) : (clean.isEmpty ? 'video' : clean);
  }
}
