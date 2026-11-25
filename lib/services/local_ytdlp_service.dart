import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api/api_client.dart';

/// Ошибка локального yt-dlp. [message] — уже готовый для показа текст
/// (обычно stderr yt-dlp или причина, почему движок не запустился).
class LocalYtdlpException implements Exception {
  final String message;
  LocalYtdlpException(this.message);
  @override
  String toString() => message;
}

/// Одно видео из плейлиста (по «плоскому» списку, без загрузки подробностей).
class PlaylistEntry {
  final String url;
  final String title;
  final int duration;
  final String? uploader;
  final String? thumbnail;
  const PlaylistEntry({
    required this.url,
    required this.title,
    required this.duration,
    this.uploader,
    this.thumbnail,
  });
}

class PlaylistInfo {
  final String title;
  final List<PlaylistEntry> entries;
  const PlaylistInfo({required this.title, required this.entries});
}

/// Итог обновления yt-dlp внутри приложения.
class YtdlpUpdateResult {
  final String before;
  final String after;
  final String detail;
  const YtdlpUpdateResult(this.before, this.after, this.detail);
  bool get changed => before != after;
}

/// Селектор формата и сортировка для yt-dlp — те же, что использует сервер
/// (`ytdlp_worker.py`), чтобы результат не зависел от способа скачивания.
class LocalFormat {
  final String format;
  final String sort;
  /// 'm4a' или 'mp3' — скачать только звук; пусто — обычное видео.
  final String audioFormat;
  const LocalFormat(this.format, this.sort, [this.audioFormat = '']);
}

/// yt-dlp, запущенный ПРЯМО НА ТЕЛЕФОНЕ (библиотека youtubedl-android внутри
/// APK; нативная часть — android/.../YtDlpBridge.kt, канал
/// `com.videovault/ytdlp`). Скачивание идёт напрямую с сайта на телефон, без
/// сервера: один этап, обычный IP телефона, склейка видео+аудио через
/// встроенный ffmpeg.
class LocalYtdlpService {
  LocalYtdlpService._() {
    _channel.setMethodCallHandler(_onNativeCall);
  }
  static final LocalYtdlpService instance = LocalYtdlpService._();

  static const MethodChannel _channel = MethodChannel('com.videovault/ytdlp');

  /// Слушатели прогресса по id скачивания.
  final Map<String, void Function(double percent, int etaSeconds)> _progressListeners = {};
  bool _initialized = false;

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'progress') {
      final args = call.arguments;
      if (args is Map) {
        final id = args['id']?.toString();
        final listener = id == null ? null : _progressListeners[id];
        listener?.call(
          (args['progress'] as num?)?.toDouble() ?? 0,
          (args['eta'] as num?)?.toInt() ?? 0,
        );
      }
    }
    return null;
  }

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw LocalYtdlpException(e.message ?? 'Ошибка yt-dlp (${e.code})');
    } on MissingPluginException {
      throw LocalYtdlpException('yt-dlp на телефоне недоступен в этой сборке приложения');
    }
  }

  /// Первый запуск распаковывает Python, yt-dlp и ffmpeg (несколько секунд).
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    await _invoke<String>('init');
    _initialized = true;
  }

  /// Версия yt-dlp внутри приложения (проверка, что движок вообще работает).
  Future<String> version() async {
    await ensureInitialized();
    final v = await _invoke<String>('version');
    return (v ?? '').trim();
  }

  /// Обновляет yt-dlp внутри приложения до последней версии. Нужно регулярно:
  /// в библиотеку зашита версия на момент её выпуска, а YouTube меняется почти
  /// каждую неделю.
  Future<YtdlpUpdateResult> update() async {
    await ensureInitialized();
    final res = await _invoke<Map>('update');
    final result = YtdlpUpdateResult(
      (res?['before'] ?? '?').toString(),
      (res?['after'] ?? '?').toString(),
      (res?['detail'] ?? '').toString(),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyLastUpdate, DateTime.now().millisecondsSinceEpoch);
    return result;
  }

  static const _keyLastUpdate = 'ytdlp_last_update_ms';

  bool _autoUpdating = false;
  DateTime? _lastAutoUpdate;

  /// Тихое автообновление при каждом входе в приложение. Возвращает результат,
  /// только если версия реально поменялась (иначе null).
  /// Пропускается, если:
  /// • обновление уже идёт;
  /// • прошло меньше [minInterval] с прошлой попытки — при частом сворачивании
  ///   и открытии не дёргаем GitHub каждый раз;
  /// • [isBusy] вернул true — идёт скачивание, подменять yt-dlp под ним нельзя.
  /// Любая ошибка (нет сети и т.п.) молча игнорируется: повторится при
  /// следующем входе.
  Future<YtdlpUpdateResult?> autoUpdate({
    Duration minInterval = const Duration(minutes: 20),
    bool Function()? isBusy,
  }) async {
    if (_autoUpdating) return null;
    final last = _lastAutoUpdate;
    if (last != null && DateTime.now().difference(last) < minInterval) return null;
    if (isBusy != null && isBusy()) return null;
    _autoUpdating = true;
    _lastAutoUpdate = DateTime.now();
    try {
      final result = await update();
      return result.changed ? result : null;
    } catch (_) {
      return null;
    } finally {
      _autoUpdating = false;
    }
  }

  /// Ссылка ведёт на плейлист, а не на отдельный ролик: YouTube `/playlist?list=…`
  /// или `list=` без `v=`. (Ролик в плейлисте — `watch?v=…&list=…` — это одно видео.)
  static bool looksLikePlaylist(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host.endsWith('youtube.com') || host == 'youtu.be') {
      if (uri.path.startsWith('/playlist')) return true;
      final hasList = (uri.queryParameters['list'] ?? '').isNotEmpty;
      final hasVideo = (uri.queryParameters['v'] ?? '').isNotEmpty ||
          (host == 'youtu.be' && uri.pathSegments.isNotEmpty);
      return hasList && !hasVideo;
    }
    return false;
  }

  /// Список видео плейлиста (быстро: без загрузки подробностей каждого).
  Future<PlaylistInfo> fetchPlaylist(String url) async {
    await ensureInitialized();
    final raw = await _invoke<String>('playlist', {'url': url});
    final text = raw ?? '';
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw LocalYtdlpException('yt-dlp вернул пустой ответ');
    }
    final dynamic decoded = jsonDecode(text.substring(start, end + 1));
    if (decoded is! Map) throw LocalYtdlpException('yt-dlp вернул неожиданный ответ');
    final j = decoded.cast<String, dynamic>();

    final entries = <PlaylistEntry>[];
    final rawEntries = j['entries'];
    if (rawEntries is List) {
      for (final e in rawEntries) {
        if (e is! Map) continue;
        if (e['_type'] == 'playlist') continue; // вложенные плейлисты не раскрываем
        final title = (e['title'] ?? '').toString();
        // Недоступные видео в плоском списке выглядят как «[Private video]» / «[Deleted video]».
        if (title.startsWith('[') && title.endsWith(']')) continue;
        final id = e['id']?.toString();
        var link = (e['url'] ?? e['webpage_url'])?.toString() ?? '';
        if (!link.startsWith('http')) {
          if (id == null || id.isEmpty) continue;
          link = 'https://www.youtube.com/watch?v=$id';
        }
        final isYoutube = link.contains('youtube.com') || link.contains('youtu.be');
        entries.add(PlaylistEntry(
          url: link,
          title: title.isEmpty ? 'video' : title,
          duration: (e['duration'] as num?)?.toInt() ?? 0,
          uploader: (e['uploader'] ?? e['channel'])?.toString(),
          // Обложка YouTube по id — без отдельного запроса на каждое видео.
          thumbnail: (isYoutube && id != null && id.isNotEmpty)
              ? 'https://i.ytimg.com/vi/$id/hqdefault.jpg'
              : null,
        ));
      }
    }
    return PlaylistInfo(
      title: (j['title'] ?? 'Плейлист').toString(),
      entries: entries,
    );
  }

  /// Метаданные видео, полученные на телефоне.
  Future<VideoInfo> fetchInfo(String url) async {
    await ensureInitialized();
    final raw = await _invoke<String>('info', {'url': url});
    return parseInfoJson(raw ?? '');
  }

  /// Скачивает видео в [outDir] как `<id>.<ext>` и возвращает путь к файлу.
  /// Прогресс yt-dlp считается отдельно для каждой дорожки (видео, потом
  /// аудио), поэтому процент может «сбрасываться» — это нормально.
  Future<String> download({
    required String url,
    required String outDir,
    required String id,
    required String quality,
    bool keepOnFailure = false,
    void Function(double percent, int etaSeconds)? onProgress,
  }) async {
    await ensureInitialized();
    final fmt = formatFor(quality);
    if (onProgress != null) _progressListeners[id] = onProgress;
    try {
      final path = await _invoke<String>('download', {
        'url': url,
        'outDir': outDir,
        'id': id,
        'format': fmt.format,
        'sort': fmt.sort,
        'audioFormat': fmt.audioFormat,
        // true — при ошибке не удалять недокачанное: повторный запуск с тем же id
        // продолжит загрузку с места обрыва.
        'keepOnFailure': keepOnFailure,
      });
      if (path == null || path.isEmpty) {
        throw LocalYtdlpException('yt-dlp не вернул путь к файлу');
      }
      return path;
    } finally {
      _progressListeners.remove(id);
    }
  }

  Future<void> cancel(String id) async {
    try {
      await _invoke<bool>('cancel', {'id': id});
    } catch (_) {}
  }

  /// "720" → лучшее до 720p; "best" (или что-то нечисловое) → лучшее доступное.
  /// Те же строки, что в ytdlp_worker.py на сервере.
  static LocalFormat formatFor(String quality) {
    // Только звук: «audio_m4a» / «audio_mp3».
    if (quality == 'audio_m4a' || quality == 'audio_mp3') {
      return LocalFormat('bestaudio[ext=m4a]/bestaudio/best', '',
          quality == 'audio_mp3' ? 'mp3' : 'm4a');
    }
    final h = int.tryParse(quality.replaceAll(RegExp(r'\D'), ''));
    if (h != null && h > 0) {
      return LocalFormat(
        'bestvideo[height<=$h]+bestaudio/best[height<=$h]/best',
        'res:$h,ext:mp4:m4a,+codec:avc:m4a',
      );
    }
    return const LocalFormat('bestvideo+bestaudio/best', 'res,ext:mp4:m4a,+codec:avc:m4a');
  }

  /// Разбирает вывод `yt-dlp --dump-single-json` в [VideoInfo]: список качеств
  /// и оценки размеров считаются так же, как на сервере (app.py,
  /// `_try_one_client_for_info` и `_quality_sizes`).
  static VideoInfo parseInfoJson(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw LocalYtdlpException('yt-dlp вернул пустой ответ');
    }
    final dynamic decoded = jsonDecode(raw.substring(start, end + 1));
    if (decoded is! Map) {
      throw LocalYtdlpException('yt-dlp вернул неожиданный ответ');
    }
    final j = decoded.cast<String, dynamic>();

    final formats = <Map<String, dynamic>>[];
    final rawFormats = j['formats'];
    if (rawFormats is List) {
      for (final f in rawFormats) {
        if (f is Map) formats.add(f.cast<String, dynamic>());
      }
    }

    String vc(Map<String, dynamic> f) => (f['vcodec'] as String?) ?? 'none';
    String ac(Map<String, dynamic> f) => (f['acodec'] as String?) ?? 'none';
    num? n(dynamic v) => v is num ? v : null;

    final duration = n(j['duration'])?.toInt() ?? 0;

    int? sizeOf(Map<String, dynamic> f) {
      final sz = n(f['filesize']) ?? n(f['filesize_approx']);
      if (sz != null && sz > 0) return sz.toInt();
      final tbr = n(f['tbr']);
      if (tbr != null && duration > 0) return (tbr * 1000 / 8 * duration).toInt();
      return null;
    }

    final heights = <int>{};
    for (final f in formats) {
      final h = n(f['height']);
      if (h != null && h >= 240 && vc(f) != 'none') heights.add(h.toInt());
    }
    final sortedHeights = heights.toList()..sort((a, b) => b.compareTo(a));

    // Лучшая аудиодорожка (m4a предпочтительнее) — её размер добавляется к
    // видеодорожкам, которые идут отдельно от звука.
    var audioSize = 0;
    final audioFormats = formats.where((f) => ac(f) != 'none' && vc(f) == 'none').toList();
    if (audioFormats.isNotEmpty) {
      double audioScore(Map<String, dynamic> f) =>
          (f['ext'] == 'm4a' ? 1000000.0 : 0.0) + (n(f['abr'])?.toDouble() ?? 0.0);
      audioFormats.sort((a, b) => audioScore(b).compareTo(audioScore(a)));
      audioSize = sizeOf(audioFormats.first) ?? 0;
    }

    final sizes = <String, int>{};
    for (final h in sortedHeights) {
      final candidates = formats.where((f) => n(f['height'])?.toInt() == h && vc(f) != 'none').toList();
      if (candidates.isEmpty) continue;
      double videoScore(Map<String, dynamic> f) {
        final preferred = f['ext'] == 'mp4' || vc(f).contains('avc');
        return (preferred ? 1000000.0 : 0.0) + (n(f['tbr'])?.toDouble() ?? 0.0);
      }

      candidates.sort((a, b) => videoScore(b).compareTo(videoScore(a)));
      final best = candidates.first;
      var sz = sizeOf(best);
      if (sz == null) continue;
      if (ac(best) == 'none') sz += audioSize;
      sizes['$h'] = sz;
    }

    // Оценки для режима «только звук»: m4a — размер лучшей аудиодорожки, mp3 —
    // по длительности (~220 кбит/с при --audio-quality 0).
    if (audioSize > 0) sizes['audio_m4a'] = audioSize;
    if (duration > 0) sizes['audio_mp3'] = (duration * 220 * 1000 / 8).round();

    return VideoInfo(
      title: (j['title'] ?? 'video').toString(),
      duration: duration,
      thumbnail: j['thumbnail'] as String?,
      platform: (j['extractor_key'] ?? j['extractor'] ?? '').toString().toLowerCase(),
      uploader: (j['uploader'] ?? j['channel'] ?? '').toString(),
      qualities: sortedHeights.isEmpty ? ['best'] : sortedHeights.map((h) => '$h').toList(),
      qualitySizes: sizes,
    );
  }
}
