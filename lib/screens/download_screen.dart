import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../api/api_client.dart';
import '../models/database.dart';
import '../services/download_service.dart';

class DownloadScreen extends StatefulWidget {
  final String? initialUrl;
  final VoidCallback? onUrlConsumed;

  const DownloadScreen({super.key, this.initialUrl, this.onUrlConsumed});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final _urlCtrl = TextEditingController();
  final _api = ApiClient();
  final _downloader = DownloadService();
  final _db = AppDatabase();

  VideoInfo? _info;
  String? _selectedQuality;
  int? _selectedAlbumId;
  String? _selectedAlbumName;
  List<Album> _albums = [];

  bool _fetchingInfo = false;
  bool _downloading = false;
  double _downloadProgress = 0;
  String _statusText = '';

  @override
  void initState() {
    super.initState();
    _loadAlbums();
    if (widget.initialUrl != null) {
      _urlCtrl.text = widget.initialUrl!;
      widget.onUrlConsumed?.call();
      WidgetsBinding.instance.addPostFrameCallback((_) => _fetchInfo());
    }
  }

  Future<void> _loadAlbums() async {
    final albums = await _db.getAlbums();
    if (mounted) setState(() => _albums = albums);
  }

  Future<void> _fetchInfo() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() { _fetchingInfo = true; _info = null; _statusText = ''; });
    try {
      final info = await _api.fetchInfo(url);
      if (mounted) setState(() {
        _info = info;
        _selectedQuality = info.qualities.first;
        _fetchingInfo = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _fetchingInfo = false;
        _statusText = '❌ $e';
      });
    }
  }

  Future<void> _download() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty || _downloading) return;

    setState(() { _downloading = true; _downloadProgress = 0; _statusText = 'Starting…'; });

    try {
      await _downloader.download(
        url: url,
        quality: _selectedQuality ?? 'best',
        albumId: _selectedAlbumId,
        onProgress: (p, speed) {
          if (mounted) setState(() {
            _downloadProgress = p;
            _statusText = '${(p * 100).toInt()}%  •  $speed/s downloaded';
          });
        },
      );
      if (mounted) {
        setState(() { _downloading = false; _statusText = ''; _info = null; });
        _urlCtrl.clear();
        _showSnack('✅ Video downloaded!');
      }
    } catch (e) {
      if (mounted) setState(() {
        _downloading = false;
        _statusText = '❌ Error: $e';
      });
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.primary;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Download Video',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: purple)),
            const SizedBox(height: 24),

            // ── URL Input ───────────────────────────────────────────────
            _card(children: [
              const Text('Video URL', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    keyboardType: TextInputType.url,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Paste YouTube, TikTok, Instagram link…',
                      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                    onSubmitted: (_) => _fetchInfo(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.paste),
                  color: Colors.white54,
                  onPressed: () async {
                    // paste from clipboard
                    final data = await _getClipboard();
                    if (data != null) { _urlCtrl.text = data; _fetchInfo(); }
                  },
                ),
              ]),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _fetchingInfo ? null : _fetchInfo,
                icon: _fetchingInfo
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.info_outline),
                label: Text(_fetchingInfo ? 'Fetching…' : 'Get video info'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E1E2A),
                  foregroundColor: purple,
                  side: BorderSide(color: purple),
                  minimumSize: const Size(double.infinity, 44),
                ),
              ),
            ]),

            // ── Video Info Preview ──────────────────────────────────────
            if (_info != null) ...[
              const SizedBox(height: 16),
              _card(children: [
                Row(children: [
                  if (_info!.thumbnail != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: _info!.thumbnail!,
                        width: 100, height: 60, fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                            width: 100, height: 60, color: const Color(0xFF1E1E2A),
                            child: const Icon(Icons.video_file, color: Colors.white38)),
                      ),
                    ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_info!.title,
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Row(children: [
                        _badge(_platformEmoji(_info!.platform) + ' ' + _info!.platform.toUpperCase(), purple),
                        const SizedBox(width: 8),
                        Text(_info!.durationFormatted,
                            style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ]),
                    ],
                  )),
                ]),
              ]),
            ],

            // ── Options ─────────────────────────────────────────────────
            const SizedBox(height: 16),
            _card(children: [
              const Text('Options', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 12),

              // Quality
              _optionRow(
                icon: Icons.hd,
                label: 'Quality',
                value: _selectedQuality != null ? '${_selectedQuality}p' : 'Select after fetch',
                onTap: _info == null ? null : _pickQuality,
              ),
              const Divider(color: Color(0xFF2A2A38), height: 24),

              // Album
              _optionRow(
                icon: Icons.folder_outlined,
                label: 'Album',
                value: _selectedAlbumName ?? 'No album',
                onTap: _pickAlbum,
              ),
              const Divider(color: Color(0xFF2A2A38), height: 24),

              // New album
              TextButton.icon(
                onPressed: _createAlbum,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('Create new album'),
                style: TextButton.styleFrom(foregroundColor: purple),
              ),
            ]),

            // ── Download Button ──────────────────────────────────────────
            const SizedBox(height: 20),
            if (_downloading) ...[
              LinearProgressIndicator(value: _downloadProgress,
                  backgroundColor: const Color(0xFF1E1E2A),
                  valueColor: AlwaysStoppedAnimation(purple)),
              const SizedBox(height: 8),
              Text(_statusText, style: const TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 16),
            ],

            if (_statusText.isNotEmpty && !_downloading)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_statusText,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),

            ElevatedButton.icon(
              onPressed: _downloading ? null : _download,
              icon: _downloading
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download),
              label: Text(_downloading ? 'Downloading…' : 'Download'),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  Widget _card({required List<Widget> children}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF16161E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _optionRow({
    required IconData icon, required String label,
    required String value, VoidCallback? onTap,
  }) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Row(children: [
          Icon(icon, size: 20, color: Colors.white38),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
            Text(value, style: const TextStyle(color: Colors.white, fontSize: 14)),
          ])),
          const Icon(Icons.chevron_right, color: Colors.white38),
        ]),
      );

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
      );

  String _platformEmoji(String p) {
    switch (p) {
      case 'youtube': return '▶️';
      case 'tiktok': return '🎵';
      case 'instagram': return '📸';
      case 'twitter': return '🐦';
      default: return '🌐';
    }
  }

  void _pickQuality() {
    final qualities = _info?.qualities ?? [];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16161E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16),
            child: Text('Select quality', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
        ...qualities.map((q) => ListTile(
          title: Text('${q}p'),
          trailing: _selectedQuality == q ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
          onTap: () { setState(() => _selectedQuality = q); Navigator.pop(context); },
        )),
        const SizedBox(height: 16),
      ]),
    );
  }

  void _pickAlbum() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16161E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16),
            child: Text('Select album', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
        ListTile(
          leading: const Icon(Icons.folder_off_outlined),
          title: const Text('No album'),
          onTap: () { setState(() { _selectedAlbumId = null; _selectedAlbumName = null; }); Navigator.pop(context); },
        ),
        ..._albums.map((a) => ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(a.name),
          trailing: _selectedAlbumId == a.id ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
          onTap: () { setState(() { _selectedAlbumId = a.id; _selectedAlbumName = a.name; }); Navigator.pop(context); },
        )),
        const SizedBox(height: 16),
      ]),
    );
  }

  void _createAlbum() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16161E),
        title: const Text('New album'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'Album name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                final id = await _db.insertAlbum(Album(name: name));
                await _loadAlbums();
                if (mounted) setState(() { _selectedAlbumId = id; _selectedAlbumName = name; });
              }
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<String?> _getClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    } catch (_) { return null; }
  }

  @override
  void dispose() { _urlCtrl.dispose(); super.dispose(); }
}
