import '../models/database.dart';
import 'download_service.dart';
import 'playback_manager.dart';

/// Полное удаление видео: файл, обложка и записи в БД. Если среди удаляемых
/// сейчас играет видео — плеер закрывается, иначе он держал бы удалённый файл.
Future<void> deleteVideosCompletely(List<Video> videos) async {
  final db = AppDatabase();
  final dl = DownloadService();
  final playing = PlaybackManager.instance.currentVideo;
  if (playing != null && videos.any((v) => v.id == playing.id)) {
    await PlaybackManager.instance.close();
  }
  for (final v in videos) {
    try {
      await dl.deleteVideoFile(v.filePath);
      await dl.deleteThumbnail(v.thumbnailPath);
    } catch (_) {
      // Файла уже может не быть — запись из библиотеки всё равно убираем.
    }
    if (v.id != null) await db.deleteVideo(v.id!);
  }
}
