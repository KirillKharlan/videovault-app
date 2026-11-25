import 'dart:io';
import 'package:flutter/material.dart';
import '../models/database.dart';
import '../services/settings_service.dart';
import '../services/gallery_import_service.dart';
import '../widgets/video_card.dart';
import '../widgets/video_actions_sheet.dart';
import '../widgets/selection_bar.dart';
import '../services/video_delete_service.dart';
import 'player_screen.dart';

/// Сортировка списка видео на главном экране.
enum HomeSort { newest, oldest, title, uploader, duration }

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
    // Сменили режим (видео/музыка) или сортировку — перестраиваем список.
    SettingsService.instance.addListener(_onSettings);
  }

  @override
  void dispose() {
    DBChangeNotifier.instance.removeListener(_load);
    SettingsService.instance.removeListener(_onSettings);
    super.dispose();
  }

  void _onSettings() {
    if (!mounted) return;
    setState(() => _videos = _sorted(_videos));
  }

  HomeSort get _sort => HomeSort.values.firstWhere(
        (s) => s.name == SettingsService.instance.homeSort,
        orElse: () => HomeSort.newest,
      );

  static String _sortLabel(HomeSort s) {
    switch (s) {
      case HomeSort.newest:   return 'Сначала новые';
      case HomeSort.oldest:   return 'Сначала старые';
      case HomeSort.title:    return 'По названию';
      case HomeSort.uploader: return 'По исполнителю (автору)';
      case HomeSort.duration: return 'По длительности';
    }
  }

  List<Video> _sorted(List<Video> list) {
    final l = List<Video>.of(list);
    int byTitle(Video a, Video b) => a.title.toLowerCase().compareTo(b.title.toLowerCase());
    switch (_sort) {
      case HomeSort.newest:
        l.sort((a, b) => b.addedAt.compareTo(a.addedAt));
        break;
      case HomeSort.oldest:
        l.sort((a, b) => a.addedAt.compareTo(b.addedAt));
        break;
      case HomeSort.title:
        l.sort(byTitle);
        break;
      case HomeSort.uploader:
        // По автору (А–Я), внутри автора — по названию; видео без автора (старые) в конце.
        l.sort((a, b) {
          final ua = (a.uploader ?? '').toLowerCase();
          final ub = (b.uploader ?? '').toLowerCase();
          if (ua.isEmpty != ub.isEmpty) return ua.isEmpty ? 1 : -1;
          final c = ua.compareTo(ub);
          return c != 0 ? c : byTitle(a, b);
        });
        break;
      case HomeSort.duration:
        l.sort((a, b) => b.duration.compareTo(a.duration));
        break;
    }
    return l;
  }

  /// «Продолжить просмотр»: начатые, но не досмотренные видео, последние
  /// просмотренные сверху. Только в режиме «Видео» и без поискового запроса.
  List<Video> get _continueWatching {
    if (_search.isNotEmpty || SettingsService.instance.mode != PlaybackMode.video) return const [];
    final list = _videos.where((v) {
      if (v.lastPlayedAt == null || v.duration <= 0) return false;
      final total = v.duration * 1000;
      return v.lastPositionMs > 10000 && v.lastPositionMs < total - 10000;
    }).toList()
      ..sort((a, b) => b.lastPlayedAt!.compareTo(a.lastPlayedAt!));
    return list.take(10).toList();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final videos = _search.isEmpty
        ? await _db.getAllVideos()
        : await _db.searchVideos(_search);
    if (mounted) setState(() { _videos = _sorted(videos); _loading = false; });
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
                PopupMenuButton<HomeSort>(
                  icon: const Icon(Icons.sort, color: Colors.white54),
                  tooltip: 'Сортировка',
                  onSelected: (s) => SettingsService.instance.setHomeSort(s.name),
                  itemBuilder: (_) => [
                    for (final s in HomeSort.values)
                      CheckedPopupMenuItem<HomeSort>(
                        value: s,
                        checked: _sort == s,
                        child: Text(_sortLabel(s)),
                      ),
                  ],
                ),
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
    final continueList = _continueWatching;
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (continueList.isNotEmpty)
            SliverToBoxAdapter(child: _buildContinueRow(continueList)),
          SliverPadding(
            padding: const EdgeInsets.all(8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.75,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => VideoCard(
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
                childCount: _videos.length,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Горизонтальная лента «Продолжить просмотр» над сеткой.
  Widget _buildContinueRow(List<Video> list) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Text('Продолжить просмотр',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ),
      SizedBox(
        height: 132,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (ctx, i) {
            final v = list[i];
            final progress = (v.lastPositionMs / (v.duration * 1000)).clamp(0.0, 1.0).toDouble();
            final thumb = v.thumbnailPath;
            return GestureDetector(
              onTap: () async {
                final index = _videos.indexWhere((x) => x.id == v.id);
                await Navigator.push(ctx,
                    MaterialPageRoute(builder: (_) => PlayerScreen(
                      video: v,
                      playlist: _videos,
                      initialIndex: index < 0 ? 0 : index,
                    )));
                _load();
              },
              child: SizedBox(
                width: 150,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      height: 84,
                      width: 150,
                      child: Stack(fit: StackFit.expand, children: [
                        if (thumb != null && File(thumb).existsSync())
                          Image.file(File(thumb), fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1E1E2A)))
                        else
                          Container(color: const Color(0xFF1E1E2A),
                              child: const Icon(Icons.video_file, color: Colors.white24)),
                        const Center(child: Icon(Icons.play_circle_fill, size: 30, color: Colors.white70)),
                        Positioned(
                          left: 0, right: 0, bottom: 0,
                          child: LinearProgressIndicator(
                            value: progress, minHeight: 3,
                            backgroundColor: Colors.black45,
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(v.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11)),
                ]),
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 8),
    ]);
  }
}
