import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

// ─── Reactive change notifier ────────────────────────────────────────────────
//
// Любой экран может подписаться на DBChangeNotifier.instance и автоматически
// перезагружать данные при любом изменении БД (добавили видео на другой
// вкладке — список на "Videos" сам обновится, без ручной кнопки Refresh).
class DBChangeNotifier extends ChangeNotifier {
  DBChangeNotifier._internal();
  static final DBChangeNotifier instance = DBChangeNotifier._internal();

  void bump() => notifyListeners();
}

// ─── Models ──────────────────────────────────────────────────────────────────

class Album {
  final int? id;
  final String name;
  final String? coverPath;
  final DateTime createdAt;

  Album({this.id, required this.name, this.coverPath, DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'cover_path': coverPath,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory Album.fromMap(Map<String, dynamic> m) => Album(
        id: m['id'],
        name: m['name'],
        coverPath: m['cover_path'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at']),
      );

  Album copyWith({int? id, String? name, String? coverPath}) => Album(
        id: id ?? this.id,
        name: name ?? this.name,
        coverPath: coverPath ?? this.coverPath,
        createdAt: createdAt,
      );
}

class Video {
  final int? id;
  final String title;
  final String filePath;
  final String? thumbnailPath;
  final String? sourceUrl;
  final String? platform;
  final int duration;      // секунды
  final int fileSize;      // байты
  final int? albumId;
  final DateTime addedAt;

  Video({
    this.id,
    required this.title,
    required this.filePath,
    this.thumbnailPath,
    this.sourceUrl,
    this.platform,
    this.duration = 0,
    this.fileSize = 0,
    this.albumId,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'file_path': filePath,
        'thumbnail_path': thumbnailPath,
        'source_url': sourceUrl,
        'platform': platform,
        'duration': duration,
        'file_size': fileSize,
        'album_id': albumId,
        'added_at': addedAt.millisecondsSinceEpoch,
      };

  factory Video.fromMap(Map<String, dynamic> m) => Video(
        id: m['id'],
        title: m['title'],
        filePath: m['file_path'],
        thumbnailPath: m['thumbnail_path'],
        sourceUrl: m['source_url'],
        platform: m['platform'],
        duration: m['duration'] ?? 0,
        fileSize: m['file_size'] ?? 0,
        albumId: m['album_id'],
        addedAt: DateTime.fromMillisecondsSinceEpoch(m['added_at']),
      );

  Video copyWith({
    int? id, String? title, String? filePath, String? thumbnailPath,
    String? sourceUrl, String? platform, int? duration, int? fileSize,
    int? albumId, bool clearAlbum = false,
  }) => Video(
        id: id ?? this.id,
        title: title ?? this.title,
        filePath: filePath ?? this.filePath,
        thumbnailPath: thumbnailPath ?? this.thumbnailPath,
        sourceUrl: sourceUrl ?? this.sourceUrl,
        platform: platform ?? this.platform,
        duration: duration ?? this.duration,
        fileSize: fileSize ?? this.fileSize,
        albumId: clearAlbum ? null : (albumId ?? this.albumId),
        addedAt: addedAt,
      );

  String get durationFormatted {
    if (duration <= 0) return '';
    final m = duration ~/ 60;
    final s = duration % 60;
    if (m >= 60) {
      return '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String get fileSizeFormatted {
    if (fileSize == 0) return '';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    return '${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class RepeatRange {
  final int? id;
  final int videoId;
  final String label;
  final int startMs;
  final int endMs;
  final bool isDefault;
  final String endBehavior; // 'loop' | 'next'

  RepeatRange({
    this.id,
    required this.videoId,
    required this.label,
    required this.startMs,
    required this.endMs,
    this.isDefault = false,
    this.endBehavior = 'loop',
  });

  Duration get start => Duration(milliseconds: startMs);
  Duration get end => Duration(milliseconds: endMs);

  String get rangeLabel {
    String fmt(Duration d) {
      final m = d.inMinutes;
      final s = d.inSeconds % 60;
      return '$m:${s.toString().padLeft(2, '0')}';
    }
    return '${fmt(start)} — ${fmt(end)}';
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'video_id': videoId,
        'label': label,
        'start_ms': startMs,
        'end_ms': endMs,
        'is_default': isDefault ? 1 : 0,
        'end_behavior': endBehavior,
      };

  factory RepeatRange.fromMap(Map<String, dynamic> m) => RepeatRange(
        id: m['id'],
        videoId: m['video_id'],
        label: m['label'],
        startMs: m['start_ms'],
        endMs: m['end_ms'],
        isDefault: (m['is_default'] ?? 0) == 1,
        endBehavior: m['end_behavior'] ?? 'loop',
      );

  RepeatRange copyWith({
    int? id, int? videoId, String? label, int? startMs, int? endMs,
    bool? isDefault, String? endBehavior,
  }) => RepeatRange(
        id: id ?? this.id,
        videoId: videoId ?? this.videoId,
        label: label ?? this.label,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        isDefault: isDefault ?? this.isDefault,
        endBehavior: endBehavior ?? this.endBehavior,
      );
}

// ─── Search normalization ─────────────────────────────────────────────────────
//
// Убирает всё что не буква/цифра (пробелы, запятые, дефисы и т.п.) и приводит
// к нижнему регистру. Так "бла бла бла" и "бла, бла, бла" совпадают при поиске.
String normalizeForSearch(String s) {
  return s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
}

// ─── Database ─────────────────────────────────────────────────────────────────

class AppDatabase {
  static final AppDatabase _instance = AppDatabase._internal();
  factory AppDatabase() => _instance;
  AppDatabase._internal();

  Database? _db;

  Future<Database> get db async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final path = join(await getDatabasesPath(), 'videovault.db');
    return openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE albums (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            cover_path TEXT,
            created_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE videos (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            file_path TEXT NOT NULL,
            thumbnail_path TEXT,
            source_url TEXT,
            platform TEXT,
            duration INTEGER DEFAULT 0,
            file_size INTEGER DEFAULT 0,
            album_id INTEGER REFERENCES albums(id) ON DELETE SET NULL,
            added_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE repeat_ranges (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            is_default INTEGER DEFAULT 0,
            end_behavior TEXT DEFAULT 'loop'
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS repeat_ranges (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              video_id INTEGER NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
              label TEXT NOT NULL,
              start_ms INTEGER NOT NULL,
              end_ms INTEGER NOT NULL,
              is_default INTEGER DEFAULT 0,
              end_behavior TEXT DEFAULT 'loop'
            )
          ''');
        }
      },
    );
  }

  // ── Albums ─────────────────────────────────────────────────────────────

  Future<List<Album>> getAlbums() async {
    final d = await db;
    final rows = await d.query('albums', orderBy: 'created_at DESC');
    return rows.map(Album.fromMap).toList();
  }

  Future<int> insertAlbum(Album album) async {
    final d = await db;
    final id = await d.insert('albums', album.toMap());
    DBChangeNotifier.instance.bump();
    return id;
  }

  Future<void> updateAlbum(Album album) async {
    final d = await db;
    await d.update('albums', album.toMap(), where: 'id = ?', whereArgs: [album.id]);
    DBChangeNotifier.instance.bump();
  }

  Future<void> deleteAlbum(int id) async {
    final d = await db;
    await d.delete('albums', where: 'id = ?', whereArgs: [id]);
    DBChangeNotifier.instance.bump();
  }

  // ── Videos ─────────────────────────────────────────────────────────────

  Future<List<Video>> getAllVideos() async {
    final d = await db;
    final rows = await d.query('videos', orderBy: 'added_at DESC');
    return rows.map(Video.fromMap).toList();
  }

  Future<List<Video>> getVideosByAlbum(int albumId) async {
    final d = await db;
    final rows = await d.query('videos',
        where: 'album_id = ?', whereArgs: [albumId], orderBy: 'added_at DESC');
    return rows.map(Video.fromMap).toList();
  }

  /// Поиск игнорирует регистр и любые символы-разделители (запятые, дефисы,
  /// пробелы и т.п.) — "бла бла бла" находит "бла, бла, бла".
  Future<List<Video>> searchVideos(String query) async {
    final all = await getAllVideos();
    final normQuery = normalizeForSearch(query);
    if (normQuery.isEmpty) return all;
    return all.where((v) => normalizeForSearch(v.title).contains(normQuery)).toList();
  }

  Future<int> insertVideo(Video video) async {
    final d = await db;
    final id = await d.insert('videos', video.toMap());
    DBChangeNotifier.instance.bump();
    return id;
  }

  Future<void> updateVideo(Video video) async {
    final d = await db;
    await d.update('videos', video.toMap(), where: 'id = ?', whereArgs: [video.id]);
    DBChangeNotifier.instance.bump();
  }

  /// Массово присвоить альбом нескольким видео разом (для мультивыбора).
  Future<void> setAlbumForVideos(List<int> videoIds, int? albumId) async {
    final d = await db;
    final batch = d.batch();
    for (final id in videoIds) {
      batch.update('videos', {'album_id': albumId}, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
    DBChangeNotifier.instance.bump();
  }

  Future<void> deleteVideo(int id) async {
    final d = await db;
    await d.delete('videos', where: 'id = ?', whereArgs: [id]);
    DBChangeNotifier.instance.bump();
  }

  Future<Video?> getVideoById(int id) async {
    final d = await db;
    final rows = await d.query('videos', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? Video.fromMap(rows.first) : null;
  }

  // ── Repeat ranges ─────────────────────────────────────────────────────

  Future<List<RepeatRange>> getRangesForVideo(int videoId) async {
    final d = await db;
    final rows = await d.query('repeat_ranges',
        where: 'video_id = ?', whereArgs: [videoId], orderBy: 'id ASC');
    return rows.map(RepeatRange.fromMap).toList();
  }

  Future<RepeatRange?> getDefaultRange(int videoId) async {
    final d = await db;
    final rows = await d.query('repeat_ranges',
        where: 'video_id = ? AND is_default = 1', whereArgs: [videoId], limit: 1);
    return rows.isNotEmpty ? RepeatRange.fromMap(rows.first) : null;
  }

  Future<int> createRange(RepeatRange range) async {
    final d = await db;
    late int id;
    await d.transaction((txn) async {
      if (range.isDefault) {
        await txn.update('repeat_ranges', {'is_default': 0},
            where: 'video_id = ?', whereArgs: [range.videoId]);
      }
      final map = range.toMap()..remove('id');
      id = await txn.insert('repeat_ranges', map);
    });
    DBChangeNotifier.instance.bump();
    return id;
  }

  /// Делает диапазон [rangeId] единственным дефолтным для видео [videoId].
  /// Если [rangeId] == null — снимает флаг "по умолчанию" со всех диапазонов видео.
  Future<void> setDefaultRange(int videoId, int? rangeId) async {
    final d = await db;
    await d.transaction((txn) async {
      await txn.update('repeat_ranges', {'is_default': 0},
          where: 'video_id = ?', whereArgs: [videoId]);
      if (rangeId != null) {
        await txn.update('repeat_ranges', {'is_default': 1},
            where: 'id = ?', whereArgs: [rangeId]);
      }
    });
    DBChangeNotifier.instance.bump();
  }

  Future<void> deleteRange(int id) async {
    final d = await db;
    await d.delete('repeat_ranges', where: 'id = ?', whereArgs: [id]);
    DBChangeNotifier.instance.bump();
  }
}
