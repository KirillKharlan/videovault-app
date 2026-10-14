import 'package:flutter/material.dart';
import '../models/database.dart';
import '../services/gallery_import_service.dart';
import '../widgets/video_card.dart';
import '../widgets/video_actions_sheet.dart';
import '../widgets/selection_bar.dart';
import '../services/video_delete_service.dart';
import 'player_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = AppDatabase();
  final _importer = GalleryImportService();
  List<Video> _videos = [];
  String _search = '';
  bool _loading = true;
  bool _importing = false;

  // ── Режим выбора нескольких видео (для удаления) ─────────────────────
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
      if (_selected.isEmpty) _selecting = false; // снял последнюю — выходим
    });
  }

  Future<void> _deleteSelected() async {
    final toDelete = _videos.where((v) => _selected.contains(v.id)).toList();
    if (toDelete.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Удалить ${toDelete.length} видео?'),
        content: const Text('Файлы будут удалены с устройства безвозвратно, '
            'видео пропадёт и из всех альбомов.'),
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
    // Автообновление: если видео добавлено на другой вкладке (Download)
    // или удалено/перемещено в плеере — список сам обновится, без кнопки.
    DBChangeNotifier.instance.addListener(_load);
  }

  @override
  void dispose() {
    DBChangeNotifier.instance.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final videos = _search.isEmpty
        ? await _db.getAllVideos()
        : await _db.searchVideos(_search);
    if (mounted) setState(() { _videos = videos; _loading = false; });
  }

  Future<void> _importFromGallery() async {
    setState(() => _importing = true);
    try {
      final video = await _importer.importFromGallery();
      if (mounted && video != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Video imported!')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Import failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _exitSelection(); // "назад" выходит из выбора
      },
      child: Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            if (_selecting)
              SelectionBar(
                count: _selected.length,
                onClose: _exitSelection,
                onSelectAll: () => setState(() {
                  _selected..clear()..addAll(_videos.map((v) => v.id!));
                }),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    tooltip: 'Удалить выбранные',
                    onPressed: _selected.isEmpty ? null : _deleteSelected,
                  ),
                ],
              )
            else
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(children: [
                Text('VideoVault',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary)),
                const Spacer(),
                _importing
                    ? const SizedBox(width: 24, height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(
                        icon: const Icon(Icons.photo_library_outlined),
                        tooltip: 'Import from gallery',
                        onPressed: _importFromGallery,
                        color: Colors.white54),
              ]),
            ),

            // Search
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                onChanged: (v) { _search = v; _load(); },
                decoration: const InputDecoration(
                  hintText: 'Search videos…',
                  prefixIcon: Icon(Icons.search, color: Colors.white38),
                  contentPadding: EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Content
            Expanded(child: _buildContent()),
          ],
        ),
      ),
    ));
  }

  Widget _buildContent() {
    if (_loading && _videos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_videos.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('📱', style: TextStyle(fontSize: 64)),
          const SizedBox(height: 16),
          const Text('No videos yet',
              style: TextStyle(fontSize: 20, color: Colors.white70)),
          const SizedBox(height: 8),
          const Text('Go to Download tab, or import from gallery',
              style: TextStyle(color: Colors.white38)),
        ]),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 0.75,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
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
    );
  }
}
