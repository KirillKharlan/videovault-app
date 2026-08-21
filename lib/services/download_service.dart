import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
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

  /// Повторяет [action] при сетевых сбоях (обрыв соединения, таймаут,
  /// DNS-ошибка) — именно такие ошибки типичны когда сервер "просыпается"
  /// после сна или Wi-Fi на телефоне на секунду проседает. Не повторяет
  /// ошибки, пришедшие явно ОТ сервера (например "видео недоступно") —
  /// они осмысленные и повтор их не исправит.
  Future<T> _withRetry<T>(
    Future<T> Function() action, {
    int maxAttempts = 3,
    Duration delay = const Duration(seconds: 3),
    void Function(int attempt)? onRetry,
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await action();
      } catch (e) {
        final isNetworkError = _isNetworkError(e);
        final isLastAttempt = attempt == maxAttempts;
        if (!isNetworkError || isLastAttempt) rethrow;
        onRetry?.call(attempt);
        await Future.delayed(delay);
      }
    }
    throw Exception('Unreachable');
  }

  bool _isNetworkError(Object e) {
    if (e is SocketException) return true;
    if (e is TimeoutException) return true;
    if (e is http.ClientException) return true; // из api_client.dart (package:http)
    if (e is DioException) {
      return e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.unknown;
    }
    return false;
  }

  /// [info] — результат /api/info, если уже был получен (даёт duration,
  ///          thumbnail URL, platform без повторного запроса).
  /// [customTitle] — если задан и не пустой, используется вместо названия
  ///          с сервера (переименование видео при скачивании).
  Future<Video> download({
    required String url,
    required String quality,
    int? albumId,
    String? customTitle,
    VideoInfo? info,
    void Function(double progress, String step)? onProgress,
  }) async {
    await initNotifications();
    // Не даём телефону "усыпить" сеть/CPU на время всего скачивания —
    // особенно важно на прошивках с агрессивным энергосбережением.
    await WakelockPlus.enable();

    try {
      return await _doDownload(
        url: url, quality: quality, albumId: albumId,
        customTitle: customTitle, info: info, onProgress: onProgress,
      );
    } finally {
      await WakelockPlus.disable();
    }
  }

  Future<Video> _doDownload({
    required String url,
    required String quality,
    int? albumId,
    String? customTitle,
    VideoInfo? info,
    void Function(double progress, String step)? onProgress,
  }) async {
    onProgress?.call(0, 'Запуск загрузки…');
    _showNotif(0, 'Запуск…');

    // 1. Старт задачи — с ретраями на случай сетевого сбоя именно в
    //    момент подключения (сервер только проснулся, Wi-Fi проседает).
    final taskId = await _withRetry(
      () => _api.startDownload(url, quality),
      onRetry: (attempt) => onProgress?.call(0, 'Проблема сети, повтор ($attempt/3)…'),
    );

    // 2. Polling прогресса
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

        errorCount++;
        if (errorCount > 5) {
          _notifs.cancel(42);
          throw Exception('Потеряно соединение с сервером: $e');
        }
        onProgress?.call(0.01, 'Проблема сети, попытка $errorCount/5…');
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

    // 3. Скачиваем файл с сервера на телефон (тоже с ретраями)
    onProgress?.call(0.97, 'Сохранение на телефон…');
    final dir = await _videosDir();

    final displayTitle = (customTitle != null && customTitle.trim().isNotEmpty)
        ? customTitle.trim()
        : (progress.title ?? 'video');

    final ext = (progress.filename != null && progress.filename!.contains('.'))
        ? progress.filename!.split('.').last
        : 'mp4';
    final safeFilename = '${_sanitize(displayTitle)}_$taskId.$ext';
    final filePath = '${dir.path}/$safeFilename';

    try {
      await _withRetry(
        () => _dio.download(
          _api.fileUrl(taskId),
          filePath,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final mb = received / 1024 / 1024;
              onProgress?.call(0.97, 'Сохранение… ${mb.toStringAsFixed(1)} MB');
            }
          },
        ),
        onRetry: (attempt) => onProgress?.call(0.97, 'Проблема сети при сохранении, повтор ($attempt/3)…'),
      );
    } catch (e) {
      _notifs.cancel(42);
      throw Exception('Ошибка при сохранении файла: $e');
    }

    // 4. Скачиваем и сохраняем миниатюру (если есть URL от YouTube)
    String? thumbPath;
    final thumbUrl = info?.thumbnail;
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
      platform: info?.platform,
      duration: info?.duration ?? 0,
      fileSize: fileSize,
      albumId: albumId,
    );

    final id = await _db.insertVideo(video);
    return video.copyWith(id: id, fileSize: fileSize);
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
