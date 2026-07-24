import 'package:flutter/material.dart';
import '../models/database.dart';
import '../widgets/video_card.dart';

/// Экран выбора видео для добавления в альбом.
/// Показывает ВСЕ видео (они не удаляются из общего списка при добавлении
/// в альбом — просто у них проставляется album_id). Поддерживает
/// мультивыбор с порядковыми номерами.
class AlbumVideoPickerScreen extends StatefulWidget {
  final int albumId;
  final String albumName;
  const AlbumVideoPickerScreen({
    super.key,
    required this.albumId,
    required this.albumName,
  });

  @override
  State<AlbumVideoPickerScreen> createState() => _AlbumVideoPickerScreenState();
}

class _AlbumVideoPickerScreenState extends State<AlbumVideoPickerScreen> {
  final _db = AppDatabase();
  List<Video> _videos = [];
  bool _loading = true;
  String _search = '';

  // videoId -> порядковый номер выбора
  final Map<int, int> _selected = {};
  int _nextOrder = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final videos = _search.isEmpty
        ? await _db.getAllVideos()
        : await _db.searchVideos(_search);
    if (mounted) setState(() { _videos = videos; _loading = false; });
  }

  void _toggle(Video v) {
    if (v.id == null) return;
    setState(() {
      if (_selected.containsKey(v.id)) {
        final removedOrder = _selected.remove(v.id)!;
        // Сдвигаем номера тех, что были выбраны позже
        for (final key in _selected.keys) {
          if (_selected[key]! > removedOrder) {
            _selected[key] = _selected[key]! - 1;
          }
        }
        _nextOrder--;
      } else {
        _selected[v.id!] = _nextOrder;
        _nextOrder++;
      }
    });
  }

  Future<void> _confirm() async {
    if (_selected.isEmpty) { Navigator.pop(context); return; }
    await _db.setAlbumForVideos(_selected.keys.toList(), widget.albumId);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Text('Add to "${widget.albumName}"'),
        actions: [
          TextButton(
            onPressed: _confirm,
            child: Text(_selected.isEmpty ? 'Done' : 'Add (${_selected.length})',
                style: TextStyle(color: purple, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            onChanged: (v) { _search = v; _load(); },
            decoration: const InputDecoration(
              hintText: 'Search videos…',
              prefixIcon: Icon(Icons.search, color: Colors.white38),
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _videos.isEmpty
                  ? const Center(child: Text('No videos found',
                      style: TextStyle(color: Colors.white54)))
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        childAspectRatio: 0.75,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemCount: _videos.length,
                      itemBuilder: (ctx, i) {
                        final v = _videos[i];
                        return VideoCard(
                          video: v,
                          selectionMode: true,
                          selected: _selected.containsKey(v.id),
                          selectionOrder: _selected[v.id],
                          onTap: () => _toggle(v),
                        );
                      },
                    ),
        ),
      ]),
      floatingActionButton: _selected.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _confirm,
              icon: const Icon(Icons.check),
              label: Text('Add ${_selected.length} video${_selected.length > 1 ? 's' : ''}'),
            )
          : null,
    );
  }
}
