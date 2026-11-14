import 'dart:async';
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
  /// Открыть альбом во вкладке главного экрана (см. main.dart). Если не задан —
  /// альбом открывается отдельным экраном поверх (как раньше).
  final void Function(Album album)? onOpenAlbum;
  const AlbumsScreen({super.key, this.onOpenAlbum});
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
                    onTap: () {
                      final open = widget.onOpenAlbum;
                      if (open != null) {
                        open(_albums[i]);
                      } else {
                        Navigator.push(ctx,
                            MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: _albums[i])));
                      }
                    },
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
  /// Задан — экран встроен во вкладку главного экрана: вместо «назад» в шапке
  /// крестик, который закрывает вкладку альбома.
  final VoidCallback? onClose;
  /// Эта вкладка сейчас на экране. Нужна, чтобы системная кнопка «назад»
  /// перехватывалась только когда альбом виден (иначе скрытая вкладка
  /// блокировала бы «назад» на всех остальных).
  final bool isActive;
  const AlbumDetailScreen({super.key, required this.album, this.onClose, this.isActive = true});
  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  final _db = AppDatabase();
  List<Video> _videos = [];

  // ── Режим выбора нескольких видео ────────────────────────────────────
  bool _selecting = false;
  final Set<int> _selected = {};

  // ── Перенос видео (перетаскивание в режиме выбора) ───────────────────
  final ScrollController _scroll = ScrollController();
  bool _dragging = false;
  Timer? _autoScroll;
  static bool _dragHintShown = false; // подсказку показываем один раз за запуск

  void _enterSelection(Video v) {
    setState(() { _selecting = true; _selected..clear()..add(v.id!); });
    if (!_dragHintShown && _videos.length > 1) {
      _dragHintShown = true;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Зажмите видео и перетащите, чтобы изменить порядок в альбоме'),
        duration: Duration(seconds: 4),
      ));
    }
  }

  /// Переносит видео [movedId] (и все выбранные, если оно среди них) на место
  /// видео [targetId]: при движении вниз — после него, вверх — перед ним.
  /// Порядок сразу сохраняется в БД и становится порядком воспроизведения.
  void _moveVideos(int movedId, int targetId) {
    final movedIndex = _videos.indexWhere((v) => v.id == movedId);
    final targetIndex = _videos.indexWhere((v) => v.id == targetId);
    if (movedIndex < 0 || targetIndex < 0 || movedId == targetId) return;
    final movingIds = _selected.contains(movedId) ? _selected.toSet() : {movedId};
    if (movingIds.contains(targetId)) return;

    final moving = _videos.where((v) => movingIds.contains(v.id)).toList();
    final rest = _videos.where((v) => !movingIds.contains(v.id)).toList();
    var at = rest.indexWhere((v) => v.id == targetId);
    if (movedIndex < targetIndex) at += 1;
    rest.insertAll(at, moving);

    setState(() => _videos = rest);
    _db.setAlbumOrder(widget.album.id!, rest.map((v) => v.id!).toList());
  }

  void _startAutoScroll(int direction) {
    _autoScroll?.cancel();
    _autoScroll = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      final next = (pos.pixels + direction * 14.0).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      _scroll.jumpTo(next.toDouble());
    });
  }

  void _stopAutoScroll() {
    _autoScroll?.cancel();
    _autoScroll = null;
  }

  void _endDrag() {
    _stopAutoScroll();
    if (mounted && _dragging) setState(() => _dragging = false);
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
    _stopAutoScroll();
    _scroll.dispose();
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

  /// Одна ячейка сетки. В режиме выбора её можно зажать и перетащить на место
  /// другого видео (LongPressDraggable + DragTarget); вне режима выбора
  /// зажатие открывает меню видео, как раньше.
  Widget _buildCell(BuildContext ctx, int i) {
    final video = _videos[i];
    final card = VideoCard(
      video: video,
      selectionMode: _selecting,
      selected: _selected.contains(video.id),
      onTap: () async {
        if (_selecting) { _toggleSelected(video); return; }
        await Navigator.push(ctx,
            MaterialPageRoute(builder: (_) => PlayerScreen(
              video: video,
              playlist: _videos,
              initialIndex: i,
            )));
        _load();
      },
      // В режиме выбора зажатие — это начало перетаскивания (его обрабатывает
      // LongPressDraggable ниже), поэтому собственный long press карточки отключаем.
      onLongPress: _selecting
          ? null
          : () => showVideoActionsSheet(ctx, video,
              onChanged: _load, onSelect: () => _enterSelection(video)),
    );
    if (!_selecting) return card;

    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      final movingCount = _selected.contains(video.id) ? _selected.length : 1;
      return DragTarget<int>(
        onWillAcceptWithDetails: (d) => d.data != video.id,
        onAcceptWithDetails: (d) => _moveVideos(d.data, video.id!),
        builder: (context, candidates, _) => Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: candidates.isNotEmpty
                ? Border.all(color: Theme.of(context).colorScheme.primary, width: 3)
                : null,
          ),
          child: LongPressDraggable<int>(
            data: video.id!,
            onDragStarted: () => setState(() => _dragging = true),
            onDragEnd: (_) => _endDrag(),
            onDraggableCanceled: (_, __) => _endDrag(),
            feedback: Material(
              type: MaterialType.transparency,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Stack(children: [
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.9,
                      child: VideoCard(
                        video: video, selectionMode: true, selected: true,
                        onTap: () {},
                      ),
                    ),
                  ),
                  if (movingCount > 1)
                    Positioned(
                      right: 6, top: 6,
                      child: CircleAvatar(
                        radius: 14,
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        child: Text('$movingCount',
                            style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ),
                    ),
                ]),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.25, child: card),
            child: card,
          ),
        ),
      );
    });
  }

  /// Полоса у края списка, над которой удерживают перетаскиваемое видео —
  /// пока оно там, список прокручивается.
  Widget _edgeZone({required bool top}) {
    return Positioned(
      left: 0, right: 0,
      top: top ? 0 : null,
      bottom: top ? null : 0,
      height: 72,
      child: DragTarget<int>(
        onWillAcceptWithDetails: (_) {
          _startAutoScroll(top ? -1 : 1);
          return false; // сюда видео не «кладут», только прокручивают
        },
        onLeave: (_) => _stopAutoScroll(),
        builder: (context, _, __) => Container(
          alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: top ? Alignment.topCenter : Alignment.bottomCenter,
              end: top ? Alignment.bottomCenter : Alignment.topCenter,
              colors: [Colors.white.withOpacity(0.18), Colors.transparent],
            ),
          ),
          child: Icon(top ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: Colors.white54),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final embedded = widget.onClose != null;
    return PopScope(
      // Во вкладке «назад» закрывает режим выбора, затем саму вкладку альбома;
      // как отдельный экран — как раньше (только выбор).
      canPop: embedded ? !(widget.isActive) : !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selecting) {
          _exitSelection();
        } else if (embedded) {
          widget.onClose!();
        }
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
              leading: embedded
                  ? IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Закрыть вкладку альбома',
                      onPressed: widget.onClose,
                    )
                  : null,
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
          : Stack(children: [
              GridView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2, childAspectRatio: 0.75,
                  crossAxisSpacing: 8, mainAxisSpacing: 8,
                ),
                itemCount: _videos.length,
                itemBuilder: (ctx, i) => _buildCell(ctx, i),
              ),
              // Зоны у верхнего и нижнего края: пока тащишь видео и держишь над
              // ними — список сам прокручивается (альбом может быть длинным).
              if (_dragging) ...[
                _edgeZone(top: true),
                _edgeZone(top: false),
              ],
            ]),
      ),
      floatingActionButton: (_videos.isNotEmpty && !_selecting)
          ? FloatingActionButton(onPressed: _addVideos, child: const Icon(Icons.add))
          : null,
    ));
  }
}
