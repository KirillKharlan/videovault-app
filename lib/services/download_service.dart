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

  Future<void> initNotifications() async {
    if (_notifsInit) return;
    await _notifs.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    _notifsInit = true;
  }

  Future<Video> download({
    required String url,
    required String quality,
    int? albumId,
    void Function(double progress, String step)? onProgress,
  }) async {
    await initNotifications();
    onProgress?.call(0, 'Запуск загрузки…');
    _showNotif(0, 'Запуск…');

    // 1. Старт задачи — таймаут 90 сек (сервер может просыпаться)
    final taskId = await _api.startDownload(url, quality);

    // 2. Polling прогресса
    // Если сервер перезапустился во время обновления yt-dlp —
    // ждём до 60 сек пока он поднимется и задача снова появится
    TaskProgress progress;
    int notFoundCount = 0;
    int errorCount = 0;
    const maxNotFound = 40; // 40 × 1.5 сек = 60 сек ожидания

    while (true) {
      await Future.delayed(const Duration(milliseconds: 1500));

      try {
        progress = await _api.getProgress(taskId);
        notFoundCount = 0;
        errorCount = 0;
      } catch (e) {
        final msg = e.toString();

        if (msg.contains('Задача не найдена')) {
          // Сервер перезапустился — ждём пока задача появится снова
          notFoundCount++;
          if (notFoundCount <= maxNotFound) {
            onProgress?.call(0.01,
                'Сервер обновляется… ожидание ${notFoundCount * 2} сек');
            continue;
          }
          _notifs.cancel(42);
          throw Exception(
            'Сервер перезапустился во время загрузки. '
            'Попробуйте скачать снова — теперь yt-dlp обновлён и всё заработает.',
          );
        }

        // Другие сетевые ошибки — даём 3 попытки
        errorCount++;
        if (errorCount > 3) {
          _notifs.cancel(42);
          throw Exception('Потеряно соединение с сервером: $e');
        }
        continue;
      }

      if (progress.isError) {
        _notifs.cancel(42);
        throw Exception(progress.error ?? 'Ошибка загрузки');
      }

      onProgress?.call(progress.percent / 100, progress.step);
      _showNotif(progress.percent.toInt(), progress.title ?? 'Загрузка…');

      if (progress.isDone) break;
    }

    // 3. Скачиваем файл с сервера на телефон
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
      throw Exception('Ошибка при сохранении файла: $e');
    }

    _notifs.cancel(42);
    _showDoneNotif(progress.title ?? safeFilename);

    final file = File(filePath);
    final fileSize = await file.exists() ? await file.length() : 0;

    final video = Video(
      title: progress.title ?? safeFilename,
      filePath: filePath,
      sourceUrl: url,
      platform: null,
      duration: 0,
      fileSize: fileSize,
      albumId: albumId,
    );

    final id = await _db.insertVideo(video);
    return video.copyWith(id: id, fileSize: fileSize);
  }

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
