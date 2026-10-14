import 'package:flutter/material.dart';
import '../models/database.dart';
import '../widgets/safe_bottom_sheet.dart';
import '../widgets/video_card.dart';
import '../widgets/video_actions_sheet.dart';
import '../widgets/selection_bar.dart';
import '../services/video_delete_service.dart';
import 'album_video_picker_screen.dart';
import 'player_screen.dart';

class AlbumsScreen extends StatefulWidget {
  const AlbumsScreen({super.key});
  @override
  State<AlbumsScreen> createState() => _AlbumsScreenState();
}

class _AlbumsScreenState extends State<AlbumsScreen> {
  final _db = AppDatabase();
  List<Album> _albums = [];

  @override
  void initState() {
    super.initState();
    _load();
    DBChangeNotifier.instance.addListener(_load);
  }

  @override
  void dispose() {
    DBChangeNotifier.instance.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final albums = await _db.getAlbums();
    if (mounted) setState(() => _albums = albums);
  }

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.primary;
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Text('Albums',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: purple)),
          ),
          Expanded(child: _albums.isEmpty
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('🗂️', style: TextStyle(fontSize: 64)),
                const SizedBox(height: 16),
                const Text('No albums yet', style: TextStyle(fontSize: 20, color: Colors.white70)),
                const SizedBox(height: 8),
                const Text('Tap + to create one', style: TextStyle(color: Colors.white38)),
              ]))
            : RefreshIndicator(
                onRefresh: _load,
                child: GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2, childAspectRatio: 0.85,
                    crossAxisSpacing: 10, mainAxisSpacing: 10,
                  ),
                  itemCount: _albums.length,
                  itemBuilder: (ctx, i) => _AlbumCard(
                    album: _albums[i],
                    onTap: () => Navigator.push(ctx,
                        MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: _albums[i]))),
                    onLongPress: () => _showOptions(_albums[i]),
                  ),
                ),
              )),
        ]),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createAlbum,
        child: const Icon(Icons.add),
      ),
    );
  }

  void _createAlbum() {
    final ctrl = TextEditingController();
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF16161E),
      title: const Text('New album'),
      content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'Album name')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () async {
          final name = ctrl.text.trim();
          if (name.isNotEmpty) { await _db.insertAlbum(Album(name: name)); await _load(); }
          if (mounted) Navigator.pop(context);
        }, child: const Text('Create')),
      ],
    ));
  }

  void _showOptions(Album album) {
    showSafeModalBottomSheet(context: context,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.edit), title: const Text('Rename'),
            onTap: () { Navigator.pop(context); _renameAlbum(album); }),
        ListTile(leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
            title: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
            onTap: () async {
              Navigator.pop(context);
              await _db.deleteAlbum(album.id!);
              _load();
            }),
      ]),
    );
  }

  void _renameAlbum(Album album) {
    final ctrl = TextEditingController(text: album.name);
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF16161E),
      title: const Text('Rename album'),
      content: TextField(controller: ctrl),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () async {
          final name = ctrl.text.trim();
          if (name.isNotEmpty) { await _db.updateAlbum(album.copyWith(name: name)); _load(); }
          if (mounted) Navigator.pop(context);
        }, child: const Text('Save')),
      ],
    ));
  }
}

class _AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  const _AlbumCard({required this.album, required this.onTap, required this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF16161E),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(children: [
          Expanded(child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E2A),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: const Center(child: Icon(Icons.folder, size: 56, color: Color(0xFF7C5CFC))),
          )),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }
}

// ─── Album Detail ─────────────────────────────────────────────────────────────

class AlbumDetailScreen extends StatefulWidget {
  final Album album;
  const AlbumDetailScreen({super.key, required this.album});
  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  final _db = AppDatabase();
  List<Video> _videos = [];

  // ── Режим выбора нескольких видео ────────────────────────────────────
  bool _selecting = false;
  final Set<int> _selected = {};

  void _enterSelection(Video v) {
    setState(() { _selecting = true; _selected..clear()..add(v.id!); });
  }

  void _exitSelection() {
    setState(() { _selecting = false; _selected.clear(); });
  }

  void _toggleSelected(Video v) {
    setState(() {
      if (!_selected.remove(v.id)) _selected.add(v.id!);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  List<Video> get _selectedVideos =>
      _videos.where((v) => _selected.contains(v.id)).toList();

  /// Убрать выбранные только из ЭТОГО альбома — в общей библиотеке и в
  /// других альбомах они остаются.
  Future<void> _removeSelectedFromAlbum() async {
    final ids = _selectedVideos.map((v) => v.id!).toList();
    if (ids.isEmpty) return;
    await _db.removeVideosFromAlbum(ids, widget.album.id!);
    if (!mounted) return;
    _exitSelection();
    _load();
  }

  /// Удалить выбранные совсем: файлы, обложки, из всех альбомов.
  Future<void> _deleteSelected() async {
    final toDelete = _selectedVideos;
    if (toDelete.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Удалить ${toDelete.length} видео?'),
        content: const Text('Файлы будут удалены с устройства безвозвратно, '
            'видео пропадёт и из всех альбомов. Чтобы убрать только из этого '
            'альбома — выберите «Убрать из альбома».'),
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
    await deleteVideosCompletely(toDelete);
    if (!mounted) return;
    _exitSelection();
    _load();
  }

  @override
  void initState() {
    super.initState();
    _load();
    DBChangeNotifier.instance.addListener(_load);
  }

  @override
  void dispose() {
    DBChangeNotifier.instance.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final v = await _db.getVideosByAlbum(widget.album.id!);
    if (mounted) setState(() => _videos = v);
  }

  Future<void> _addVideos() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => AlbumVideoPickerScreen(
        albumId: widget.album.id!,
        albumName: widget.album.name,
      ),
    ));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _exitSelection();
      },
      child: Scaffold(
      appBar: _selecting
          ? AppBar(
              automaticallyImplyLeading: false,
              titleSpacing: 0,
              title: SelectionBar(
                count: _selected.length,
                onClose: _exitSelection,
                onSelectAll: () => setState(() {
                  _selected..clear()..addAll(_videos.map((v) => v.id!));
                }),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.folder_off_outlined),
                    tooltip: 'Убрать из альбома',
                    onPressed: _removeSelectedFromAlbum,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    tooltip: 'Удалить совсем',
                    onPressed: _deleteSelected,
                  ),
                ],
              ),
            )
          : AppBar(
              title: Text(widget.album.name),
              actions: [
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'Add videos',
                  onPressed: _addVideos,
                ),
              ],
            ),
      body: SafeArea(
        top: false,
        child: _videos.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('📁', style: TextStyle(fontSize: 56)),
              const SizedBox(height: 12),
              const Text('No videos in this album',
                  style: TextStyle(color: Colors.white54)),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _addVideos,
                icon: const Icon(Icons.add),
                label: const Text('Add videos'),
              ),
            ]))
          : GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2, childAspectRatio: 0.75,
                crossAxisSpacing: 8, mainAxisSpacing: 8,
              ),
              itemCount: _videos.length,
              itemBuilder: (ctx, i) => VideoCard(
                video: _videos[i],
                selectionMode: _selecting,
                selected: _selected.contains(_videos[i].id),
                onTap: () async {
                  if (_selecting) { _toggleSelected(_videos[i]); return; }
                  await Navigator.push(ctx,
                      MaterialPageRoute(builder: (_) => PlayerScreen(
                        video: _videos[i],
                        playlist: _videos,
                        initialIndex: i,
                      )));
                  _load();
                },
                onLongPress: () {
                  if (_selecting) { _toggleSelected(_videos[i]); return; }
                  showVideoActionsSheet(ctx, _videos[i],
                      onChanged: _load, onSelect: () => _enterSelection(_videos[i]));
                },
              ),
            ),
      ),
      floatingActionButton: (_videos.isNotEmpty && !_selecting)
          ? FloatingActionButton(onPressed: _addVideos, child: const Icon(Icons.add))
          : null,
    ));
  }
}
