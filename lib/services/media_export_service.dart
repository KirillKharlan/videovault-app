import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:file_saver/file_saver.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

/// Экспорт локально скачанных видео: сохранение в системную галерею,
/// сохранение файла (видео или mp3) в память устройства, и конвертация
/// mp4 -> mp3 прямо на телефоне через ffmpeg (офлайн, без бэкенда).
class MediaExportService {
  MediaExportService._();
  static final instance = MediaExportService._();

  /// Конвертирует mp4 в mp3 (только аудиодорожка, без перекодирования
  /// видео — быстро). Результат кладётся во временную папку приложения,
  /// вызывающий код сам решает, что с ним делать дальше (сохранить в
  /// галерею/на устройство и т.д.).
  Future<String> convertToMp3(String videoPath) async {
    final tmpDir = await getTemporaryDirectory();
    final base = videoPath.split(Platform.pathSeparator).last
        .replaceAll(RegExp(r'\.[^.]+$'), '');
    final outPath = '${tmpDir.path}/$base.mp3';

    final existing = File(outPath);
    if (await existing.exists()) await existing.delete();

    final session = await FFmpegKit.execute(
      '-y -i "$videoPath" -vn -acodec libmp3lame -q:a 2 "$outPath"',
    );
    final code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      final logs = await session.getAllLogsAsString();
      throw Exception('Конвертация в MP3 не удалась: ${logs ?? "нет логов"}');
    }
    return outPath;
  }

  /// Сохраняет видео в системную галерею (Фото/Видео на Android, Photos
  /// на iOS). Для аудио (mp3) у Android/iOS нет эквивалента "галереи" —
  /// используйте [saveToDevice].
  Future<void> saveVideoToGallery(String filePath) async {
    await Gal.putVideo(filePath);
  }

  /// Сохраняет произвольный файл (видео или mp3) в память устройства —
  /// открывает системный диалог "Сохранить как", пользователь сам выбирает
  /// папку (обычно Downloads).
  ///
  /// Примечание: текущая реализация читает файл целиком в память перед
  /// сохранением — для очень больших видео (несколько ГБ) это может быть
  /// заметно по потреблению RAM. Для mp3 и большинства видео это не проблема.
  Future<void> saveToDevice(String filePath, {required String fileName}) async {
    final bytes = await File(filePath).readAsBytes();
    final dotIndex = fileName.lastIndexOf('.');
    final name = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
    final ext = dotIndex > 0 ? fileName.substring(dotIndex + 1) : 'mp4';
    await FileSaver.instance.saveFile(
      name: name,
      bytes: bytes,
      ext: ext,
      mimeType: ext == 'mp3' ? MimeType.mp3 : MimeType.mp4Video,
    );
  }
}
