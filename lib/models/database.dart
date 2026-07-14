import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

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

  Video copyWith({int? id, String? title, String? filePath,
      String? thumbnailPath, int? albumId, int? fileSize}) => Video(
        id: id ?? this.id,
        title: title ?? this.title,
        filePath: filePath ?? this.filePath,
        thumbnailPath: thumbnailPath ?? this.thumbnailPath,
        sourceUrl: sourceUrl,
        platform: platform,
        duration: duration,
        fileSize: fileSize ?? this.fileSize,
        albumId: albumId ?? this.albumId,
        addedAt: addedAt,
      );

  String get durationFormatted {
    final m = duration ~/ 60;
    final s = duration % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String get fileSizeFormatted {
    if (fileSize == 0) return '';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    return '${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB';
  }
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
      version: 1,
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
    return d.insert('albums', album.toMap());
  }

  Future<void> updateAlbum(Album album) async {
    final d = await db;
    await d.update('albums', album.toMap(), where: 'id = ?', whereArgs: [album.id]);
  }

  Future<void> deleteAlbum(int id) async {
    final d = await db;
    await d.delete('albums', where: 'id = ?', whereArgs: [id]);
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

  Future<List<Video>> searchVideos(String query) async {
    final d = await db;
    final rows = await d.query('videos',
        where: 'title LIKE ?', whereArgs: ['%$query%'], orderBy: 'added_at DESC');
    return rows.map(Video.fromMap).toList();
  }

  Future<int> insertVideo(Video video) async {
    final d = await db;
    return d.insert('videos', video.toMap());
  }

  Future<void> updateVideo(Video video) async {
    final d = await db;
    await d.update('videos', video.toMap(), where: 'id = ?', whereArgs: [video.id]);
  }

  Future<void> deleteVideo(int id) async {
    final d = await db;
    await d.delete('videos', where: 'id = ?', whereArgs: [id]);
  }

  Future<Video?> getVideoById(int id) async {
    final d = await db;
    final rows = await d.query('videos', where: 'id = ?', whereArgs: [id]);
    return rows.isNotEmpty ? Video.fromMap(rows.first) : null;
  }
}
