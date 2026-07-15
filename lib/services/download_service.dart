import 'dart:async';
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

  final _dio  = Dio(BaseOptions(receiveTimeout: const Duration(minutes: 30)));
  final _db   = AppDatabase();
  final _api  = ApiClient();
  final _notifs = FlutterLocalNotificationsPlugin();
  bool _notifsInit = false;

  // ─── Init ───────────────────────────────────────────────────────────────

  Future<void> initNotifications() async {
    if (_notifsInit) return;
    await _notifs.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    _notifsInit = true;
  }

  // ─── Download ───────────────────────────────────────────────────────────
  //
  // Новая схема (соответствует app.py):
  //   1. POST /api/download  → task_id
  //   2. Polling GET /api/progress/<id> каждые 1.5 сек
  //   3. Когда status == 'done' → GET /api/file/<id> → сохраняем файл

  Future<Video> download({
    required String url,
    required String quality,
    int? albumId,
    void Function(double progress, String step)? onProgress,
  }) async {
    await initNotifications();
    onProgress?.call(0, 'Запуск загрузки…');
    _showNotif(0, 'Запуск…');

    final taskId = await _api.startDownload(url, quality);

    TaskProgress progress;
    int errorCount = 0;
    
    while (true) {
      await Future.delayed(const Duration(milliseconds: 1500));
      try {
        progress = await _api.getProgress(taskId);
        errorCount = 0;
      } catch (e) {
        errorCount++;
        if (errorCount > 8) {
          _notifs.cancel(42);
          throw Exception("Потеряно соединение с сервером. Попробуйте позже.");
        }
        continue;
      }

      if (progress.isError) {
        _notifs.cancel(42);
        throw Exception(progress.error ?? 'Ошибка загрузки');
      }

      final pct = progress.percent / 100;
      onProgress?.call(pct, progress.step);
      _showNotif(progress.percent.toInt(), progress.title ?? 'Загрузка…');

      if (progress.isDone) break;
    }

    onProgress?.call(0.99, 'Сохранение на телефон…');
    final dir = await _videosDir();
    final rawFilename = progress.filename ?? 'video.mp4';
    final safeFilename = rawFilename.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final filePath = '${dir.path}/$safeFilename';

    try {
      await _dio.download(
        _api.fileUrl(taskId),
        filePath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final mb = received / 1024 / 1024;
            onProgress?.call(0.99, 'Сохранение… ${mb.toStringAsFixed(1)} MB');
          }
        },
      );
    } catch (e) {
      _notifs.cancel(42);
      throw Exception("Ошибка при сохранении файла на устройство: $e");
    }

    _notifs.cancel(42);
    _showDoneNotif(progress.title ?? safeFilename);

    final file = File(filePath);
    final fileSize = await file.exists() ? await file.length() : 0;

    int duration = 0;
    String? platform;
    try {
      final info = await _api.fetchInfo(url);
      duration = info.duration;
      platform = info.platform;
    } catch (_) {}

    final video = Video(
      title: progress.title ?? safeFilename,
      filePath: filePath,
      sourceUrl: url,
      platform: platform,
      duration: duration,
      fileSize: fileSize,
      albumId: albumId,
    );
    
    final id = await _db.insertVideo(video);
    return video.copyWith(id: id, fileSize: fileSize);
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  Future<Directory> _videosDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory('${base.path}/videos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> deleteVideoFile(String path) async {
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
