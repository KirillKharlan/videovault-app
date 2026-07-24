import 'package:flutter/material.dart';
import '../models/database.dart';
import '../services/gallery_import_service.dart';
import '../widgets/video_card.dart';
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
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
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
    );
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
          onTap: () async {
            await Navigator.push(ctx,
                MaterialPageRoute(builder: (_) => PlayerScreen(video: _videos[i])));
            _load();
          },
        ),
      ),
    );
  }
}
