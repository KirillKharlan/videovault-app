import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/database.dart';

/// Переименование скачанного видео и смена его обложки (как на YouTube —
/// своя картинка вместо автосгенерированного превью).
class VideoEditService {
  final _db = AppDatabase();
  final _picker = ImagePicker();

  Future<void> renameVideo(Video video, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty || video.id == null) return;
    await _db.updateVideoTitle(video.id!, trimmed);
  }

  /// Открывает галерею телефона, копирует выбранную картинку в папку обложек
  /// приложения и сохраняет путь как обложку видео. Возвращает true если
  /// пользователь выбрал картинку (false — отмена).
  Future<bool> changeCover(Video video) async {
    if (video.id == null) return false;
    final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (picked == null) return false;

    final thumbsDir = await _thumbsDir();
    final ext = picked.name.contains('.') ? picked.name.split('.').last : 'jpg';
    final destPath = '${thumbsDir.path}/cover_${video.id}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await File(picked.path).copy(destPath);

    // Удаляем старую кастомную обложку, чтобы не копились файлы-сироты.
    final oldPath = video.thumbnailPath;
    await _db.updateVideoThumbnail(video.id!, destPath);
    if (oldPath != null && oldPath != destPath) {
      final oldFile = File(oldPath);
      if (await oldFile.exists()) {
        try { await oldFile.delete(); } catch (_) { /* не критично */ }
      }
    }
    return true;
  }

  /// Сбрасывает обложку на автосгенерированную/плейсхолдер.
  Future<void> resetCover(Video video) async {
    if (video.id == null) return;
    final oldPath = video.thumbnailPath;
    await _db.updateVideoThumbnail(video.id!, null);
    if (oldPath != null) {
      final oldFile = File(oldPath);
      if (await oldFile.exists()) {
        try { await oldFile.delete(); } catch (_) { /* не критично */ }
      }
    }
  }

  Future<Directory> _thumbsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/thumbs');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
