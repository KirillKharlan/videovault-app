import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiClient {
  static const String baseUrl = 'https://videovault-server.onrender.com';

  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;
  ApiClient._internal();

  final _client = http.Client();

  // ─── Инфо о видео ──────────────────────────────────────────────────────
  // Таймаут 90 сек — Render спит 15-30 сек + обновление yt-dlp ~10 сек
  // refresh: true — сервер игнорирует свой кэш и заново запрашивает форматы
  // (кнопка «Обновить список качеств»).
  Future<VideoInfo> fetchInfo(String url, {bool refresh = false}) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/info'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'url': url, if (refresh) 'refresh': true}),
    ).timeout(const Duration(seconds: 90));

    if (response.statusCode == 200) {
      return VideoInfo.fromJson(jsonDecode(response.body));
    }
    final err = jsonDecode(response.body);
    throw ApiException(err['error'] ?? 'Не удалось получить инфо о видео');
  }

  // ─── Запустить скачивание → получить task_id ────────────────────────────
  // Таймаут 90 сек — сервер может быть в процессе старта
  Future<String> startDownload(String url, String quality) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/download'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'url': url, 'quality': quality}),
    ).timeout(const Duration(seconds: 90));

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return json['task_id'] as String;
    }
    final err = jsonDecode(response.body);
    throw ApiException(err['error'] ?? 'Не удалось запустить загрузку');
  }

  // ─── Один запрос — сразу видео (POST /api/fetch) ────────────────────────
  // Сервер отвечает одним из трёх способов:
  //  • video/mp4 — прямой поток: тело ответа и есть файл, приходит ПО МЕРЕ
  //    скачивания сервером (заголовки приходят уже с первым байтом);
  //  • JSON {"mode":"task","task_id":...} — прямой путь не подошёл (нужна
  //    склейка видео+аудио, mp3 и т.п.) → дальше прежняя схема:
  //    getProgress() + fileUrl();
  //  • 400 + JSON {"error":...} — содержательная ошибка про само видео.
  // Старый сервер без /api/fetch (404/405) → сразу запасной путь startDownload.
  // Таймаут 3 мин — это ожидание ЗАГОЛОВКОВ ответа (сервер может проснуться и
  // перебирать клиентов до первого байта); тело потока ограничивается отдельно.
  Future<FetchResult> fetch(String url, String quality) async {
    final request = http.Request('POST', Uri.parse('$baseUrl/api/fetch'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'url': url, 'quality': quality});
    final response = await _client.send(request).timeout(const Duration(minutes: 3));
    final contentType = response.headers['content-type'] ?? '';

    if (response.statusCode == 200 && contentType.startsWith('video/')) {
      final size = int.tryParse(response.headers['x-file-size'] ?? '');
      String? title;
      final rawTitle = response.headers['x-title'];
      if (rawTitle != null && rawTitle.isNotEmpty) {
        try {
          title = Uri.decodeComponent(rawTitle);
        } catch (_) {
          title = null;
        }
      }
      return FetchResult.stream(response, estimatedSize: size, title: title);
    }

    final body = await response.stream.bytesToString();
    if (response.statusCode == 200) {
      final json = jsonDecode(body);
      if (json is Map && json['task_id'] is String) {
        return FetchResult.task(json['task_id'] as String);
      }
    }
    if (response.statusCode == 404 || response.statusCode == 405) {
      return FetchResult.task(await startDownload(url, quality));
    }
    if (response.statusCode >= 500) {
      // 502/503 — Render просыпается или перезапускается: сетевая ошибка,
      // _withRetry в download_service.dart повторит запрос.
      throw http.ClientException('Сервер временно недоступен (${response.statusCode})');
    }
    var message = 'Не удалось запустить загрузку';
    try {
      final err = jsonDecode(body);
      if (err is Map && err['error'] is String) message = err['error'] as String;
    } catch (_) {}
    throw ApiException(message);
  }

  // ─── Прогресс задачи ────────────────────────────────────────────────────
  Future<TaskProgress> getProgress(String taskId) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/progress/$taskId'),
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      return TaskProgress.fromJson(jsonDecode(response.body));
    }
    throw ApiException('Задача не найдена');
  }

  String fileUrl(String taskId) => '$baseUrl/api/file/$taskId';

  Future<bool> checkHealth() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

// ─── Модели ─────────────────────────────────────────────────────────────────

/// Результат [ApiClient.fetch]: либо прямой поток видео, либо task_id для
/// прежней схемы (опрос прогресса + скачивание готового файла).
class FetchResult {
  final String? taskId;
  final http.StreamedResponse? response;
  /// Оценка размера по данным сервера — может быть неточной или null.
  final int? estimatedSize;
  final String? title;

  FetchResult.task(String id)
      : taskId = id,
        response = null,
        estimatedSize = null,
        title = null;

  FetchResult.stream(http.StreamedResponse r, {this.estimatedSize, this.title})
      : taskId = null,
        response = r;

  bool get isStream => response != null;
}

class VideoInfo {
  final String title;
  final int duration;
  final String? thumbnail;
  final String platform;
  final String uploader;
  final List<String> qualities;
  /// Оценка размера файла по качеству в байтах (ключ — высота без «p»).
  /// Есть не для всех качеств, у старого сервера пусто.
  final Map<String, int> qualitySizes;

  VideoInfo({
    required this.title,
    required this.duration,
    this.thumbnail,
    required this.platform,
    required this.uploader,
    required this.qualities,
    this.qualitySizes = const {},
  });

  static Map<String, int> _parseSizes(dynamic raw) {
    final out = <String, int>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is num) out[k.toString().replaceAll('p', '')] = v.toInt();
      });
    }
    return out;
  }

  /// «1080p» для числового качества, иначе (сервер не смог определить
  /// высоты — значение «best») — «Лучшее доступное».
  String qualityLabel(String q) =>
      RegExp(r'^\d+$').hasMatch(q) ? '${q}p' : 'Лучшее доступное';

  /// «~85 МБ» / «~1.2 ГБ», либо null, если оценки нет.
  String? qualitySizeLabel(String q) {
    final bytes = qualitySizes[q];
    if (bytes == null || bytes <= 0) return null;
    final mb = bytes / 1024 / 1024;
    return mb >= 1024 ? '~${(mb / 1024).toStringAsFixed(1)} ГБ' : '~${mb.round()} МБ';
  }

  /// «1080p · ~85 МБ» (или просто «1080p», если размер неизвестен).
  String qualityFullLabel(String q) {
    final size = qualitySizeLabel(q);
    return size == null ? qualityLabel(q) : '${qualityLabel(q)} · $size';
  }

  factory VideoInfo.fromJson(Map<String, dynamic> j) => VideoInfo(
        title:     j['title']    ?? 'Unknown',
        duration:  j['duration'] ?? 0,
        thumbnail: j['thumbnail'],
        platform:  j['platform'] ?? 'other',
        uploader:  j['uploader'] ?? '',
        // Убираем лишнюю 'p' если сервер вдруг её пришлёт
        qualities: List<String>.from(j['qualities'] ?? ['best'])
            .map((q) => q.replaceAll('p', ''))
            .toList(),
        qualitySizes: _parseSizes(j['quality_sizes']),
      );

  String get durationFormatted {
    final m = duration ~/ 60, s = duration % 60;
    if (m >= 60) return '${m ~/ 60}:${(m % 60).toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class TaskProgress {
  final String status;
  final double percent;
  final String step;
  final String? title;
  final String? error;
  final String? errorType;
  final int? fileSize;
  final String? filename;

  TaskProgress({
    required this.status,
    required this.percent,
    required this.step,
    this.title,
    this.error,
    this.errorType,
    this.fileSize,
    this.filename,
  });

  factory TaskProgress.fromJson(Map<String, dynamic> j) => TaskProgress(
        status:    j['status']   ?? 'unknown',
        percent:   (j['percent'] ?? 0).toDouble(),
        step:      j['step']     ?? '',
        title:     j['title'],
        error:     j['error'],
        errorType: j['error_type'],
        fileSize:  j['file_size'],
        filename:  j['filename'],
      );

  bool get isDone   => status == 'done';
  bool get isError  => status == 'error';
  bool get isActive => !isDone && !isError;
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}
