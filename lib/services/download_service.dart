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

  final _dio = Dio();
  final _db = AppDatabase();
  final _api = ApiClient();
  final _notifs = FlutterLocalNotificationsPlugin();

  bool _notifsInit = false;

  // Активные загрузки: url → CancelToken
  final Map<String, CancelToken> _active = {};

  // ─── Init ───────────────────────────────────────────────────────────────

  Future<void> initNotifications() async {
    if (_notifsInit) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifs.initialize(const InitializationSettings(android: android));
    _notifsInit = true;
  }

  // ─── Download ───────────────────────────────────────────────────────────

  /// Скачивает видео, сохраняет в БД, возвращает Video
  Future<Video> download({
    required String url,
    required String quality,
    int? albumId,
    void Function(double progress, String speed)? onProgress,
  }) async {
    await initNotifications();

    // 1. Получаем прямую ссылку с сервера
    _showNotification(0, 'Getting video info…');
    final info = await _api.getDownloadUrl(url, quality);

    // 2. Папка для видео
    final dir = await _videosDir();
    final safeTitle = info.title
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .substring(0, info.title.length.clamp(0, 80));
    final filePath = '${dir.path}/$safeTitle.mp4';

    // 3. Скачиваем с прогрессом
    final cancelToken = CancelToken();
    _active[url] = cancelToken;

    await _dio.download(
      info.downloadUrl,
      filePath,
      cancelToken: cancelToken,
      options: Options(
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/91.0.4472.120 Mobile Safari/537.36',
          'Referer': 'https://www.youtube.com/',
        },
        receiveTimeout: const Duration(minutes: 30),
      ),
      onReceiveProgress: (received, total) {
        if (total <= 0) return;
        final progress = received / total;
        final speedMb = received / 1024 / 1024;
        _showNotification(
            (progress * 100).toInt(), '${info.title.substring(0, info.title.length.clamp(0, 30))}…');
        onProgress?.call(progress, '${speedMb.toStringAsFixed(1)} MB');
      },
    );

    _active.remove(url);

    // 4. Сохраняем в БД
    final file = File(filePath);
    final video = Video(
      title: info.title,
      filePath: filePath,
      sourceUrl: url,
      platform: info.platform,
      duration: 0,
      fileSize: await file.exists() ? await file.length() : 0,
      albumId: albumId,
    );

    final id = await _db.insertVideo(video);
    _showDoneNotification(info.title);

    return video.copyWith(id: id, fileSize: video.fileSize);
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

  // ─── Notifications ──────────────────────────────────────────────────────

  void _showNotification(int progress, String text) {
    _notifs.show(
      42,
      'VideoVault',
      text,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'downloads', 'Downloads',
          channelDescription: 'Download progress',
          importance: Importance.low,
          priority: Priority.low,
          showProgress: true,
          maxProgress: 100,
          progress: progress,
          ongoing: true,
        ),
      ),
    );
  }

  void _showDoneNotification(String title) {
    _notifs.cancel(42);
    _notifs.show(
      43,
      'Downloaded ✅',
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
