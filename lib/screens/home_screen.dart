import 'package:flutter/material.dart';
import '../models/database.dart';
import '../widgets/video_card.dart';
import 'player_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _db = AppDatabase();
  List<Video> _videos = [];
  String _search = '';
  bool _loading = true;

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
                IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _load,
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
    if (_loading) {
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
          Text('Go to Download tab to add videos',
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
