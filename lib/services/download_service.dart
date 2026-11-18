import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../api/api_client.dart';
import '../models/database.dart';
import 'local_ytdlp_service.dart';

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  final _dio  = Dio(BaseOptions(receiveTimeout: const Duration(minutes: 30)));
  final _db   = AppDatabase();
  final _notifs = FlutterLocalNotificationsPlugin();
  bool _notifsInit = false;

  Future<void> initNotifications() async {
    if (_notifsInit) return;
    await _notifs.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    _notifsInit = true;
  }

  /// [info] — результат /api/info, если уже был получен (даёт duration,
  ///          thumbnail URL, platform без повторного запроса).
  /// [customTitle] — если задан и не пустой, используется вместо названия
  ///          с сервера (переименование видео при скачивании).
  Future<Video> download({
    required String url,
    required String quality,
    int? albumId,
    int? Function()? albumIdResolver,
    String? customTitle,
    VideoInfo? info,
    Future<VideoInfo?>? infoFuture,
    void Function(double progress, String step)? onProgress,
  }) async {
    await initNotifications();
    // Не даём телефону "усыпить" сеть/CPU на время всего скачивания —
    // особенно важно на прошивках с агрессивным энергосбережением.
    await WakelockPlus.enable();

    try {
      // Скачивание всегда идёт на телефоне: yt-dlp встроен в приложение
      // (см. local_ytdlp_service.dart).
      return await _doDownloadLocal(
        url: url, quality: quality, albumId: albumId,
        albumIdResolver: albumIdResolver,
        customTitle: customTitle, info: info, infoFuture: infoFuture,
        onProgress: onProgress,
      );
    } finally {
      await WakelockPlus.disable();
    }
  }

  /// Финал загрузки: миниатюра, уведомление
  /// и запись в БД. [filePath] — уже лежащий на месте итоговый файл.
  Future<Video> _finishVideo({
    required String url,
    required String filePath,
    required String displayTitle,
    required String taskId,
    required VideoInfo? resolvedInfo,
    required int? albumId,
    required int? Function()? albumIdResolver,
    void Function(double progress, String step)? onProgress,
  }) async {
    // 4. Скачиваем и сохраняем миниатюру (если есть URL от YouTube)
    String? thumbPath;
    final thumbUrl = resolvedInfo?.thumbnail;
    if (thumbUrl != null && thumbUrl.isNotEmpty) {
      onProgress?.call(0.99, 'Сохранение превью…');
      thumbPath = await _downloadThumbnail(thumbUrl, taskId);
    }

    _notifs.cancel(42);
    _showDoneNotif(displayTitle);

    final file = File(filePath);
    final fileSize = await file.exists() ? await file.length() : 0;

    final video = Video(
      title: displayTitle,
      filePath: filePath,
      thumbnailPath: thumbPath,
      sourceUrl: url,
      platform: resolvedInfo?.platform,
      duration: resolvedInfo?.duration ?? 0,
      fileSize: fileSize,
      // Альбом выбирают и меняют в очереди прямо во время скачивания —
      // берём актуальное значение на момент сохранения, а не на старте.
      albumId: albumIdResolver != null ? albumIdResolver() : albumId,
    );

    final id = await _db.insertVideo(video);
    return video.copyWith(id: id, fileSize: fileSize);
  }

  /// Скачивание ПРЯМО НА ТЕЛЕФОНЕ через yt-dlp, встроенный в приложение
  /// (см. local_ytdlp_service.dart): без сервера, один этап. Файл сразу
  /// появляется в папке видео, дальше — тот же финал, что и у серверной схемы.
  Future<Video> _doDownloadLocal({
    required String url,
    required String quality,
    int? albumId,
    int? Function()? albumIdResolver,
    String? customTitle,
    VideoInfo? info,
    Future<VideoInfo?>? infoFuture,
    void Function(double progress, String step)? onProgress,
  }) async {
    final local = LocalYtdlpService.instance;
    onProgress?.call(0, 'Запуск yt-dlp на телефоне…');
    _showNotif(0, 'Запуск…');

    VideoInfo? resolvedInfo = info;
    if (resolvedInfo == null && infoFuture != null) {
      try {
        resolvedInfo = await infoFuture.timeout(const Duration(seconds: 20));
      } catch (_) {
        resolvedInfo = null;
      }
    }

    final dir = await _videosDir();
    await _cleanupStaleParts(dir);
    final localId = 'l${DateTime.now().millisecondsSinceEpoch}';
    final notifTitle = resolvedInfo?.title ?? 'Загрузка…';

    final String producedPath;
    try {
      producedPath = await local.download(
        url: url,
        outDir: dir.path,
        id: localId,
        quality: quality,
        onProgress: (percent, eta) {
          final p = percent.clamp(0.0, 100.0).toDouble();
          final etaText = eta > 0 ? ' · ещё $eta с' : '';
          onProgress?.call(p / 100 * 0.97, 'На телефоне: ${p.toStringAsFixed(0)}%$etaText');
          _showNotif(p.toInt(), notifTitle);
        },
      );
    } catch (_) {
      _notifs.cancel(42);
      rethrow;
    }

    // Инфо не пришла заранее (редкий случай) — запрашиваем уже после скачивания,
    // чтобы не остаться без названия/обложки; не вышло — не критично.
    if (resolvedInfo == null) {
      try {
        resolvedInfo = await local.fetchInfo(url).timeout(const Duration(seconds: 40));
      } catch (_) {
        resolvedInfo = null;
      }
    }

    final displayTitle = (customTitle != null && customTitle.trim().isNotEmpty)
        ? customTitle.trim()
        : (resolvedInfo?.title ?? 'video');

    final producedName = producedPath.split('/').last;
    final ext = producedName.contains('.') ? producedName.split('.').last : 'mp4';
    final filePath = '${dir.path}/${_sanitize(displayTitle)}_$localId.$ext';
    try {
      await File(producedPath).rename(filePath);
    } catch (e) {
      _notifs.cancel(42);
      throw Exception('Ошибка при сохранении файла: $e');
    }

    return _finishVideo(
      url: url, filePath: filePath, displayTitle: displayTitle, taskId: localId,
      resolvedInfo: resolvedInfo, albumId: albumId, albumIdResolver: albumIdResolver,
      onProgress: onProgress,
    );
  }

  /// Недокачанное (приложение убили посреди загрузки) остаётся в папке видео как
  /// `l<число>.*` (файлы yt-dlp до переименования) или старые `dl_*.part` — удаляем
  /// такие, если им больше часа. Готовые видео переименовываются в `<название>_l<id>.mp4`
  /// и под эти шаблоны не попадают.
  Future<void> _cleanupStaleParts(Directory dir, {String keep = ''}) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in dir.list()) {
        if (entity is! File || entity.path == keep) continue;
        final name = entity.uri.pathSegments.last;
        final isLegacyPart = name.startsWith('dl_') && name.endsWith('.part');
        final isYtdlpTemp = RegExp(r'^l\d+\.').hasMatch(name);
        if (!isLegacyPart && !isYtdlpTemp) continue;
        if ((await entity.lastModified()).isBefore(cutoff)) await entity.delete();
      }
    } catch (_) {
      // уборка не критична
    }
  }

  Future<String?> _downloadThumbnail(String url, String taskId) async {
    try {
      final dir = await _thumbsDir();
      final path = '${dir.path}/thumb_$taskId.jpg';
      await _dio.download(url, path);
      return path;
    } catch (_) {
      return null; // отсутствие превью не критично
    }
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

  Future<void> deleteVideoFile(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  Future<void> deleteThumbnail(String? path) async {
    if (path == null) return;
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  void _showNotif(int percent, String text) {
    final short = text.length > 40 ? '${text.substring(0, 40)}…' : text;
    _notifs.show(42, 'VideoVault', short, NotificationDetails(
      android: AndroidNotificationDetails(
        'downloads', 'Downloads',
        importance: Importance.low, priority: Priority.low,
        showProgress: true, maxProgress: 100, progress: percent,
        ongoing: true, onlyAlertOnce: true,
      ),
    ));
  }

  void _showDoneNotif(String title) {
    _notifs.cancel(42);
    _notifs.show(43, '✅ Загружено!', title, const NotificationDetails(
      android: AndroidNotificationDetails('downloads', 'Downloads'),
    ));
  }
}
