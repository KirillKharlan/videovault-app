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
  Future<VideoInfo> fetchInfo(String url) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/info'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'url': url}),
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

class VideoInfo {
  final String title;
  final int duration;
  final String? thumbnail;
  final String platform;
  final String uploader;
  final List<String> qualities;

  VideoInfo({
    required this.title,
    required this.duration,
    this.thumbnail,
    required this.platform,
    required this.uploader,
    required this.qualities,
  });

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
