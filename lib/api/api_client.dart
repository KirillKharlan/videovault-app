import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiClient {
  // ← Сюда вставишь свой URL с Render после деплоя
  static const String baseUrl = 'https://videovault-api.onrender.com';

  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;
  ApiClient._internal();

  final _client = http.Client();

  // ─── Получить инфо о видео ──────────────────────────────────────────────

  Future<VideoInfo> fetchInfo(String url) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/info'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'url': url}),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return VideoInfo.fromJson(json);
    } else {
      final err = jsonDecode(response.body);
      throw ApiException(err['detail'] ?? 'Failed to fetch video info');
    }
  }

  // ─── Получить прямую ссылку для скачивания ─────────────────────────────

  Future<DownloadInfo> getDownloadUrl(String url, String quality) async {
    final response = await _client
        .post(
          Uri.parse('$baseUrl/download-url'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'url': url, 'quality': quality}),
        )
        .timeout(const Duration(seconds: 45));

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return DownloadInfo.fromJson(json);
    } else {
      final err = jsonDecode(response.body);
      throw ApiException(err['detail'] ?? 'Failed to get download URL');
    }
  }

  // ─── Проверить доступность сервера ─────────────────────────────────────

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

// ─── Модели ответов ─────────────────────────────────────────────────────────

class VideoInfo {
  final String title;
  final int duration;
  final String? thumbnail;
  final String platform;
  final String uploader;
  final int viewCount;
  final List<String> qualities;

  VideoInfo({
    required this.title,
    required this.duration,
    this.thumbnail,
    required this.platform,
    required this.uploader,
    required this.viewCount,
    required this.qualities,
  });

  factory VideoInfo.fromJson(Map<String, dynamic> j) => VideoInfo(
        title: j['title'] ?? 'Unknown',
        duration: j['duration'] ?? 0,
        thumbnail: j['thumbnail'],
        platform: j['platform'] ?? 'other',
        uploader: j['uploader'] ?? '',
        viewCount: j['view_count'] ?? 0,
        qualities: List<String>.from(j['qualities'] ?? ['best']),
      );

  String get durationFormatted {
    final m = duration ~/ 60;
    final s = duration % 60;
    if (m >= 60) {
      return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

class DownloadInfo {
  final String downloadUrl;
  final String title;
  final String ext;
  final int filesize;
  final int height;
  final String platform;

  DownloadInfo({
    required this.downloadUrl,
    required this.title,
    required this.ext,
    required this.filesize,
    required this.height,
    required this.platform,
  });

  factory DownloadInfo.fromJson(Map<String, dynamic> j) => DownloadInfo(
        downloadUrl: j['download_url'],
        title: j['title'] ?? 'video',
        ext: j['ext'] ?? 'mp4',
        filesize: j['filesize'] ?? 0,
        height: j['height'] ?? 0,
        platform: j['platform'] ?? 'other',
      );
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}
