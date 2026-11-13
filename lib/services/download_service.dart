import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../api/api_client.dart';
import '../models/database.dart';
import 'local_ytdlp_service.dart';
import 'settings_service.dart';

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
    if (e is HttpException) return true; // обрыв chunked-потока ("Connection closed while receiving data")
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
      // Способ скачивания — настройка пользователя: сервер / на телефоне /
      // «авто» (сначала телефон, при любой неудаче — сервер).
      final mode = SettingsService.instance.downloadMode;
      if (mode != DownloadMode.server) {
        try {
          return await _doDownloadLocal(
            url: url, quality: quality, albumId: albumId,
            albumIdResolver: albumIdResolver,
            customTitle: customTitle, info: info, infoFuture: infoFuture,
            onProgress: onProgress,
          );
        } catch (_) {
          if (mode == DownloadMode.local) rethrow;
          onProgress?.call(0, 'На телефоне не вышло, пробую через сервер…');
        }
      }
      return await _doDownload(
        url: url, quality: quality, albumId: albumId,
        albumIdResolver: albumIdResolver,
        customTitle: customTitle, info: info, infoFuture: infoFuture,
        onProgress: onProgress,
      );
    } finally {
      await WakelockPlus.disable();
    }
  }

  Future<Video> _doDownload({
    required String url,
    required String quality,
    int? albumId,
    int? Function()? albumIdResolver,
    String? customTitle,
    VideoInfo? info,
    Future<VideoInfo?>? infoFuture,
    void Function(double progress, String step)? onProgress,
  }) async {
    onProgress?.call(0, 'Запуск загрузки…');
    _showNotif(0, 'Запуск…');

    // Сервер планирует прямой поток по инфо из своего кэша (его наполняет
    // /api/info), поэтому сначала дожидаемся инфо — обычно оно уже готово,
    // т.к. запрашивается при вставке ссылки. Не дождались за 20 сек — не
    // страшно: сервер просто пойдёт запасным путём (через задачу).
    VideoInfo? resolvedInfo = info;
    if (resolvedInfo == null && infoFuture != null) {
      try {
        resolvedInfo = await infoFuture.timeout(const Duration(seconds: 20));
      } catch (_) {
        resolvedInfo = null;
      }
    }

    final dir = await _videosDir();
    final localId = 's${DateTime.now().millisecondsSinceEpoch}';
    final partPath = '${dir.path}/dl_$localId.part';

    // 1. ОДИН запрос: либо видео сразу идёт потоком (и пишется в partPath по
    //    мере поступления), либо сервер отвечает task_id (запасной путь).
    //    Ретраи покрывают и обрыв посреди потока — тогда всё начинается заново.
    await _cleanupStaleParts(dir, keep: partPath);
    final _Fetched fetched;
    try {
      fetched = await _withRetry<_Fetched>(
        () async {
          final r = await _api.fetch(url, quality);
          if (r.isStream) {
            await _receiveStream(r, partPath, onProgress);
            return _Fetched(streamed: true, title: r.title);
          }
          return _Fetched(taskId: r.taskId);
        },
        onRetry: (attempt) => onProgress?.call(0, 'Проблема сети, повтор ($attempt/3)…'),
      );
    } catch (_) {
      _notifs.cancel(42);
      rethrow;
    }
    final streamed = fetched.streamed;
    final taskId = fetched.taskId ?? localId;

    String? serverTitleRaw = fetched.title;
    String? serverFilename;

    if (!streamed) {
      // 2. Запасной путь: polling прогресса задачи
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
      serverTitleRaw = progress.title;
      serverFilename = progress.filename;
    }

    // Инфо о видео (обложка/платформа/длительность) могла запрашиваться
    // ПАРАЛЛЕЛЬНО со скачиванием (infoFuture) — к этому моменту она, как
    // правило, давно готова, ждём только на случай, если нет. Ошибка или
    // таймаут инфо — не фатальны: видео просто сохранится без обложки.
    if (resolvedInfo == null && infoFuture != null) {
      try {
        resolvedInfo = await infoFuture.timeout(const Duration(seconds: 25));
      } catch (_) {
        resolvedInfo = null;
      }
    }

    // 3. Файл на телефоне. Прямой поток уже лежит в partPath — достаточно
    //    дать ему итоговое имя. В запасном пути файл сначала забираем с сервера.
    // "video" — плейсхолдер сервера, если название на тот момент ещё не
    // было известно; тогда берём название из инфо.
    final serverTitle = (serverTitleRaw != null && serverTitleRaw != 'video')
        ? serverTitleRaw
        : null;
    final displayTitle = (customTitle != null && customTitle.trim().isNotEmpty)
        ? customTitle.trim()
        : (serverTitle ?? resolvedInfo?.title ?? 'video');

    final ext = (serverFilename != null && serverFilename.contains('.'))
        ? serverFilename.split('.').last
        : 'mp4';
    final safeFilename = '${_sanitize(displayTitle)}_$taskId.$ext';
    final filePath = '${dir.path}/$safeFilename';

    if (streamed) {
      try {
        await File(partPath).rename(filePath);
      } catch (e) {
        _notifs.cancel(42);
        throw Exception('Ошибка при сохранении файла: $e');
      }
    } else {
      onProgress?.call(0.97, 'Сохранение на телефон…');
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
    }

    return _finishVideo(
      url: url, filePath: filePath, displayTitle: displayTitle, taskId: taskId,
      resolvedInfo: resolvedInfo, albumId: albumId, albumIdResolver: albumIdResolver,
      onProgress: onProgress,
    );
  }

  /// Общий финал любой загрузки (с сервера или с телефона): миниатюра, уведомление
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

  /// Пишет тело прямого потока в [partPath] по мере поступления. При любой
  /// ошибке (в т.ч. обрыв посреди потока) недокачанный файл удаляется — иначе
  /// он мог бы сойти за готовый. Прогресс считается по оценке размера с
  /// сервера; если оценки нет — 0 (в UI это неопределённая полоса) и счётчик МБ.
  Future<void> _receiveStream(
    FetchResult r,
    String partPath,
    void Function(double progress, String step)? onProgress,
  ) async {
    final file = File(partPath);
    final sink = file.openWrite();
    final total = r.estimatedSize;
    final label = r.title ?? 'Загрузка…';
    var received = 0;
    var lastUi = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      // 120 сек без единого байта — считаем обрывом (TimeoutException → ретрай).
      await for (final chunk in r.response!.stream.timeout(const Duration(seconds: 120))) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastUi).inMilliseconds >= 400) {
          lastUi = now;
          final mb = received / 1024 / 1024;
          final frac = (total != null && total > 0)
              ? (received / total).clamp(0.0, 0.98).toDouble()
              : 0.0;
          onProgress?.call(frac, 'Скачивание… ${mb.toStringAsFixed(1)} MB');
          _showNotif((frac * 100).toInt(), label);
        }
      }
      await sink.flush();
      await sink.close();
      if (received == 0) throw Exception('Сервер вернул пустой файл');
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Недокачанные потоки (приложение убили посреди загрузки) оставляют
  /// файлы dl_*.part — удаляем те, что старше часа и не относятся к текущей загрузке.
  Future<void> _cleanupStaleParts(Directory dir, {required String keep}) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in dir.list()) {
        if (entity is! File || entity.path == keep) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith('dl_') || !name.endsWith('.part')) continue;
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

/// Итог первого шага загрузки: либо файл уже получен прямым потоком
/// ([streamed]), либо сервер выдал [taskId] запасного пути.
class _Fetched {
  final bool streamed;
  final String? taskId;
  final String? title;
  _Fetched({this.streamed = false, this.taskId, this.title});
}
