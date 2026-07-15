import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiClient {
  // БЕЗ слеша в конце!
  static const String baseUrl = 'https://videovault-server.onrender.com';

  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;
  ApiClient._internal();

  final _client = http.Client();

  // ─── Инфо о видео ──────────────────────────────────────────────────────
  Future<VideoInfo> fetchInfo(String url) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/info'),          // ← /api/info
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'url': url}),
    ).timeout(const Duration(seconds: 45));

    if (response.statusCode == 200) {
      return VideoInfo.fromJson(jsonDecode(response.body));
    }
    final err = jsonDecode(response.body);
    throw ApiException(err['error'] ?? 'Не удалось получить инфо о видео');
  }

  // ─── Запустить скачивание → получить task_id ────────────────────────────
  Future<String> startDownload(String url, String quality) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/download'),      // ← /api/download
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'url': url, 'quality': quality}),
    ).timeout(const Duration(seconds: 30));

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
      Uri.parse('$baseUrl/api/progress/$taskId'), // ← /api/progress/<id>
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      return TaskProgress.fromJson(jsonDecode(response.body));
    }
    throw ApiException('Задача не найдена');
  }

  // ─── URL для скачивания файла ────────────────────────────────────────────
  String fileUrl(String taskId) => '$baseUrl/api/file/$taskId'; // ← /api/file/<id>

  // ─── Проверка сервера ────────────────────────────────────────────────────
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
        qualities: List<String>.from(j['qualities'] ?? ['best']),
      );

  String get durationFormatted {
    final m = duration ~/ 60, s = duration % 60;
    if (m >= 60) return '${m ~/ 60}:${(m % 60).toString().padLeft(2,'0')}:${s.toString().padLeft(2,'0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class TaskProgress {
  final String status;   // queued / fetching_info / downloading / done / error
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

  bool get isDone    => status == 'done';
  bool get isError   => status == 'error';
  bool get isActive  => !isDone && !isError;
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}
