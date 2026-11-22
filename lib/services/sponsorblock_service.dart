import 'package:dio/dio.dart';
import '../models/database.dart';
import 'settings_service.dart';

/// Автопропуск рекламных вставок в видео с YouTube по базе SponsorBlock
/// (sponsor.ajay.app). После скачивания запрашивает сегменты и сохраняет их как
/// наши «пропуски» (таблица video_skips) — дальше их уже обрабатывает плеер,
/// в том числе в фоновом режиме.
class SponsorBlockService {
  SponsorBlockService._();
  static final SponsorBlockService instance = SponsorBlockService._();

  static const _categories = ['sponsor', 'selfpromo', 'interaction'];
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));

  /// ID ролика из ссылки YouTube (watch?v=, youtu.be/, /shorts/, /embed/, /live/).
  static String? youtubeId(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    String? id;
    if (host == 'youtu.be') {
      if (uri.pathSegments.isNotEmpty) id = uri.pathSegments.first;
    } else if (host.endsWith('youtube.com') || host.endsWith('youtube-nocookie.com')) {
      id = uri.queryParameters['v'];
      if (id == null && uri.pathSegments.length >= 2 &&
          const {'shorts', 'embed', 'live', 'v'}.contains(uri.pathSegments.first)) {
        id = uri.pathSegments[1];
      }
    }
    if (id == null || !RegExp(r'^[A-Za-z0-9_-]{6,20}$').hasMatch(id)) return null;
    return id;
  }

  /// Тихо добавляет «пропуски» для [video], если функция включена и видео с
  /// YouTube. Любая ошибка (нет сети, нет сегментов) игнорируется.
  Future<void> applyTo(Video video) async {
    if (!SettingsService.instance.sponsorBlock) return;
    final videoId = video.id;
    final ytId = youtubeId(video.sourceUrl);
    if (videoId == null || ytId == null) return;
    try {
      final resp = await _dio.get<List<dynamic>>(
        'https://sponsor.ajay.app/api/skipSegments',
        queryParameters: {'videoID': ytId, 'category': _categories, 'actionType': 'skip'},
      );
      final raw = resp.data ?? const [];
      final segments = <List<int>>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final seg = item['segment'];
        if (seg is! List || seg.length < 2) continue;
        final start = ((seg[0] as num) * 1000).round();
        final end = ((seg[1] as num) * 1000).round();
        if (end - start >= 500) segments.add([start, end]);
      }
      if (segments.isEmpty) return;
      segments.sort((a, b) => a[0].compareTo(b[0]));
      // Склеиваем перекрывающиеся/соседние сегменты.
      final merged = <List<int>>[];
      for (final s in segments) {
        if (merged.isNotEmpty && s[0] <= merged.last[1] + 300) {
          if (s[1] > merged.last[1]) merged.last[1] = s[1];
        } else {
          merged.add([s[0], s[1]]);
        }
      }
      final db = AppDatabase();
      final existing = await db.getSkipsForVideo(videoId);
      for (final m in merged) {
        final dup = existing.any((e) => (e.startMs - m[0]).abs() < 500 && (e.endMs - m[1]).abs() < 500);
        if (!dup) await db.createSkip(SkipSegment(videoId: videoId, startMs: m[0], endMs: m[1]));
      }
    } catch (_) {
      // нет сети / нет данных для этого видео — не критично
    }
  }
}
