import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../api/api_client.dart';
import '../models/database.dart';

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 30),
  ));
  final _db = AppDatabase();
  final _api = ApiClient();
  final _notifs = FlutterLocalNotificationsPlugin();

  bool _notifsInit = false;
  final Map<String, CancelToken> _active = {};

  // ─── Init ───────────────────────────────────────────────────────────────

  Future<void> initNotifications() async {
    if (_notifsInit) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifs.initialize(const InitializationSettings(android: android));
    _notifsInit = true;
  }

  // ─── Download ───────────────────────────────────────────────────────────

  Future<Video> download({
    required String url,
    required String quality,
    int? albumId,
    void Function(double progress, String label)? onProgress,
  }) async {
    await initNotifications();

    onProgress?.call(0, 'Getting video info…');
    _showNotification(0, 'Getting video info…');

    // 1. Получаем прямую ссылку + заголовки с сервера
    final info = await _api.getDownloadUrl(url, quality);

    // 2. Папка для видео
    final dir = await _videosDir();
    final safeTitle = _sanitizeFilename(info.title);
    final filePath = '${dir.path}/$safeTitle.${info.ext}';

    // 3. Скачиваем с заголовками из yt-dlp
    //    ВАЖНО для yt-dlp 2026.07.04: YouTube iOS клиент возвращает
    //    URL с привязкой к User-Agent — без правильных заголовков
    //    сервер вернёт 403.
    final cancelToken = CancelToken();
    _active[url] = cancelToken;

    // Формируем заголовки: приоритет у заголовков из yt-dlp,
    // дефолтный User-Agent как запасной вариант
    final downloadHeaders = <String, dynamic>{
      'User-Agent':
          'com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)',
      ...info.headers, // перезаписывает дефолт если yt-dlp дал свои
    };

    try {
      await _dio.download(
        info.downloadUrl,
        filePath,
        cancelToken: cancelToken,
        options: Options(headers: downloadHeaders),
        onReceiveProgress: (received, total) {
          if (total <= 0) return;
          final pct = received / total;
          final mb = received / 1024 / 1024;
          final label = '${(pct * 100).toInt()}%  •  ${mb.toStringAsFixed(1)} MB';
          _showNotification((pct * 100).toInt(), info.title);
          onProgress?.call(pct, label);
        },
      );
    } on DioException catch (e) {
      _active.remove(url);
      if (CancelToken.isCancel(e)) throw Exception('Download cancelled');

      // Если 403 — значит URL протух (YouTube URLs живут ~6 часов)
      if (e.response?.statusCode == 403) {
        throw Exception(
          'Download link expired (HTTP 403). This can happen with YouTube — try again.',
        );
      }
      throw Exception('Download failed: ${e.message}');
    }

    _active.remove(url);

    // 4. Сохраняем в БД
    final file = File(filePath);
    final fileSize = await file.exists() ? await file.length() : 0;

    final video = Video(
      title: info.title,
      filePath: filePath,
      sourceUrl: url,
      platform: info.platform,
      duration: 0,
      fileSize: fileSize,
      albumId: albumId,
    );

    final id = await _db.insertVideo(video);
    _showDoneNotification(info.title);

    return video.copyWith(id: id, fileSize: fileSize);
  }

  void cancelDownload(String url) {
    _active[url]?.cancel('User cancelled');
    _active.remove(url);
  }

  // ─── Storage ────────────────────────────────────────────────────────────

  Future<Directory> _videosDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/videos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> deleteVideoFile(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  String _sanitizeFilename(String name) {
    final clean = name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Лимит длины имени файла
    return clean.length > 100 ? clean.substring(0, 100) : clean;
  }

  // ─── Notifications ──────────────────────────────────────────────────────

  void _showNotification(int progress, String title) {
    final shortTitle = title.length > 40 ? '${title.substring(0, 40)}…' : title;
    _notifs.show(
      42,
      'Downloading…',
      shortTitle,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'downloads', 'Downloads',
          channelDescription: 'Video download progress',
          importance: Importance.low,
          priority: Priority.low,
          showProgress: true,
          maxProgress: 100,
          progress: progress,
          ongoing: true,
          onlyAlertOnce: true,
        ),
      ),
    );
  }

  void _showDoneNotification(String title) {
    _notifs.cancel(42);
    _notifs.show(
      43,
      '✅ Downloaded!',
      title,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'downloads', 'Downloads',
          importance: Importance.defaultImportance,
        ),
      ),
    );
  }
}
