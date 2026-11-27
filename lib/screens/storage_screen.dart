import 'dart:io';
import 'package:flutter/material.dart';
import '../models/database.dart';
import '../services/video_delete_service.dart';

/// «Место»: сколько занимает библиотека, самые тяжёлые видео и быстрая очистка
/// (в том числе просмотренных до конца).
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  final _db = AppDatabase();
  List<Video> _videos = [];
  final Set<int> _selected = {};
  bool _loading = true;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await _db.getAllVideos();
    all.sort((a, b) => b.fileSize.compareTo(a.fileSize));
    if (!mounted) return;
    setState(() {
      _videos = all;
      _selected.removeWhere((id) => !all.any((v) => v.id == id));
      _loading = false;
    });
  }

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ';
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(0)} МБ';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
    return '$bytes Б';
  }

  /// Просмотренные до конца: когда-то смотрели (есть last_played_at), а позиция
  /// сброшена в 0 — так проигрыватель делает по окончании видео.
  List<Video> get _watched =>
      _videos.where((v) => v.lastPlayedAt != null && v.lastPositionMs == 0).toList();

  int get _total => _videos.fold(0, (sum, v) => sum + v.fileSize);
  int get _selectedBytes =>
      _videos.where((v) => _selected.contains(v.id)).fold(0, (sum, v) => sum + v.fileSize);

  Future<void> _deleteSelected() async {
    final toDelete = _videos.where((v) => _selected.contains(v.id)).toList();
    if (toDelete.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Удалить ${toDelete.length} видео?'),
        content: Text('Освободится ${_size(_selectedBytes)}. Файлы будут удалены с '
            'устройства безвозвратно, видео пропадёт и из всех альбомов.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deleting = true);
    await deleteVideosCompletely(toDelete);
    _selected.clear();
    await _load();
    if (mounted) setState(() => _deleting = false);
  }

  @override
  Widget build(BuildContext context) {
    final watched = _watched;
    final watchedBytes = watched.fold<int>(0, (sum, v) => sum + v.fileSize);
    return Scaffold(
      appBar: AppBar(title: const Text('Занятое место')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_size(_total),
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                  Text('${_videos.length} видео в библиотеке',
                      style: const TextStyle(color: Colors.white54, fontSize: 13)),
                  if (watched.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: Text(
                          'Просмотрено до конца: ${watched.length} · ${_size(watchedBytes)}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          _selected
                            ..clear()
                            ..addAll(watched.map((v) => v.id!));
                        }),
                        child: const Text('Выбрать'),
                      ),
                    ]),
                  ],
                ]),
              ),
              Expanded(
                child: _videos.isEmpty
                    ? const Center(child: Text('В библиотеке пока ничего нет',
                        style: TextStyle(color: Colors.white54)))
                    : ListView.builder(
                        itemCount: _videos.length,
                        itemBuilder: (ctx, i) {
                          final v = _videos[i];
                          final selected = _selected.contains(v.id);
                          final thumb = v.thumbnailPath;
                          return CheckboxListTile(
                            value: selected,
                            onChanged: (_) => setState(() {
                              if (!_selected.remove(v.id)) _selected.add(v.id!);
                            }),
                            controlAffinity: ListTileControlAffinity.trailing,
                            secondary: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 64, height: 40,
                                child: (thumb != null && File(thumb).existsSync())
                                    ? Image.file(File(thumb), fit: BoxFit.cover)
                                    : Container(color: const Color(0xFF1E1E2A),
                                        child: const Icon(Icons.video_file, color: Colors.white24, size: 20)),
                              ),
                            ),
                            title: Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13)),
                            subtitle: Text(
                              _size(v.fileSize) +
                                  ((v.lastPlayedAt != null && v.lastPositionMs == 0) ? ' · просмотрено' : ''),
                              style: const TextStyle(fontSize: 12, color: Colors.white54),
                            ),
                          );
                        },
                      ),
              ),
              if (_selected.isNotEmpty)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                        onPressed: _deleting ? null : _deleteSelected,
                        icon: _deleting
                            ? const SizedBox(width: 18, height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.delete_outline),
                        label: Text('Удалить (${_selected.length}) · ${_size(_selectedBytes)}'),
                      ),
                    ),
                  ),
                ),
            ]),
    );
  }
}
