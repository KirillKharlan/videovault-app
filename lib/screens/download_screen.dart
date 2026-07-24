import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../api/api_client.dart';
import '../models/database.dart';
import '../services/download_service.dart';
import '../widgets/safe_bottom_sheet.dart';

class DownloadScreen extends StatefulWidget {
  final String? initialUrl;
  final VoidCallback? onUrlConsumed;
  const DownloadScreen({super.key, this.initialUrl, this.onUrlConsumed});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  final _urlCtrl    = TextEditingController();
  final _titleCtrl  = TextEditingController();
  final _api        = ApiClient();
  final _downloader = DownloadService();
  final _db         = AppDatabase();

  VideoInfo? _info;
  String? _selectedQuality;
  int?    _selectedAlbumId;
  String? _selectedAlbumName;
  List<Album> _albums = [];

  bool   _fetchingInfo = false;
  bool   _downloading  = false;
  double _progress     = 0;
  String _statusText   = '';

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
        _titleCtrl.text = info.title;
        _selectedQuality = info.qualities.isNotEmpty ? info.qualities.first : 'best';
        _fetchingInfo = false;
      });
    } catch (e) {
      if (mounted) setState(() { _fetchingInfo = false; _statusText = '❌ $e'; });
    }
  }

  Future<void> _download() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty || _downloading) return;
    setState(() { _downloading = true; _progress = 0; _statusText = 'Запуск…'; });

    try {
      await _downloader.download(
        url: url,
        quality: _selectedQuality ?? 'best',
        albumId: _selectedAlbumId,
        customTitle: _titleCtrl.text.trim().isNotEmpty ? _titleCtrl.text.trim() : null,
        info: _info,
        onProgress: (p, step) {
          if (mounted) setState(() { _progress = p; _statusText = step; });
        },
      );
      if (mounted) {
        setState(() { _downloading = false; _statusText = ''; _info = null; });
        _urlCtrl.clear();
        _titleCtrl.clear();
        _selectedQuality = null; _selectedAlbumId = null; _selectedAlbumName = null;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Видео сохранено!')));
      }
    } catch (e) {
      if (mounted) setState(() { _downloading = false; _statusText = '❌ $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.primary;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Скачать видео',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: purple)),
            const SizedBox(height: 24),

            // URL
            _card(children: [
              const Text('Ссылка на видео', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(
                  controller: _urlCtrl,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'YouTube, TikTok, Instagram…',
                    contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                  onSubmitted: (_) => _fetchInfo(),
                )),
              ]),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _fetchingInfo ? null : _fetchInfo,
                icon: _fetchingInfo
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.info_outline),
                label: Text(_fetchingInfo ? 'Загрузка…' : 'Получить информацию'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: purple, side: BorderSide(color: purple),
                  minimumSize: const Size(double.infinity, 44),
                ),
              ),
            ]),

            // Инфо о видео + переименование
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
                        errorWidget: (_, __, ___) =>
                            Container(width: 100, height: 60, color: const Color(0xFF1E1E2A),
                                child: const Icon(Icons.video_file, color: Colors.white38)),
                      ),
                    ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      _badge(_info!.platform.toUpperCase(), purple),
                      const SizedBox(width: 8),
                      Text(_info!.durationFormatted,
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ]),
                  ])),
                ]),
                const SizedBox(height: 12),
                const Text('Название (можно изменить)',
                    style: TextStyle(color: Colors.white54, fontSize: 11)),
                const SizedBox(height: 6),
                TextField(
                  controller: _titleCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.refresh, size: 18, color: Colors.white38),
                      tooltip: 'Восстановить оригинальное название',
                      onPressed: () => setState(() => _titleCtrl.text = _info!.title),
                    ),
                  ),
                ),
              ]),
            ],

            // Опции
            const SizedBox(height: 16),
            _card(children: [
              const Text('Настройки', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 12),

              _optionRow(Icons.hd, 'Качество',
                  _selectedQuality != null
                      ? (_selectedQuality!.isNotEmpty && RegExp(r'^\d+$').hasMatch(_selectedQuality!)
                          ? '${_selectedQuality}p'
                          : _selectedQuality!)
                      : 'Выберите после загрузки инфо',
                  _info == null ? null : _pickQuality),

              const Divider(color: Color(0xFF2A2A38), height: 24),

              _optionRow(Icons.folder_outlined, 'Альбом',
                  _selectedAlbumName ?? 'Без альбома', _pickAlbum),

              const Divider(color: Color(0xFF2A2A38), height: 24),

              TextButton.icon(
                onPressed: _createAlbum,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('Создать новый альбом'),
                style: TextButton.styleFrom(foregroundColor: purple),
              ),
            ]),

            // Прогресс
            if (_downloading) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                backgroundColor: const Color(0xFF1E1E2A),
                valueColor: AlwaysStoppedAnimation(purple),
              ),
              const SizedBox(height: 8),
              Text(_statusText, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ],

            if (_statusText.isNotEmpty && !_downloading)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_statusText,
                    style: TextStyle(
                        color: _statusText.startsWith('❌') ? Colors.redAccent : Colors.white54,
                        fontSize: 13)),
              ),

            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _downloading ? null : _download,
              icon: _downloading
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download),
              label: Text(_downloading ? 'Загружается…' : 'Скачать'),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _card({required List<Widget> children}) => Container(
        width: double.infinity, padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xFF16161E),
            borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _optionRow(IconData icon, String label, String value, VoidCallback? onTap) =>
      InkWell(onTap: onTap, borderRadius: BorderRadius.circular(8),
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
        decoration: BoxDecoration(color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withOpacity(0.4))),
        child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
      );

  void _pickQuality() {
    final qualities = _info?.qualities ?? [];
    showSafeModalBottomSheet(context: context,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16),
            child: Text('Качество', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
        ...qualities.map((q) => ListTile(
          title: Text('${q}p'),
          trailing: _selectedQuality == q
              ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
          onTap: () { setState(() => _selectedQuality = q); Navigator.pop(context); },
        )),
      ]),
    );
  }

  void _pickAlbum() {
    showSafeModalBottomSheet(context: context,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16),
            child: Text('Выбрать альбом', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
        ListTile(leading: const Icon(Icons.folder_off_outlined), title: const Text('Без альбома'),
            onTap: () { setState(() { _selectedAlbumId = null; _selectedAlbumName = null; });
              Navigator.pop(context); }),
        ..._albums.map((a) => ListTile(
          leading: const Icon(Icons.folder_outlined), title: Text(a.name),
          trailing: _selectedAlbumId == a.id
              ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
          onTap: () { setState(() { _selectedAlbumId = a.id; _selectedAlbumName = a.name; });
            Navigator.pop(context); },
        )),
      ]),
    );
  }

  void _createAlbum() {
    final ctrl = TextEditingController();
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF16161E), title: const Text('Новый альбом'),
      content: TextField(controller: ctrl, decoration: const InputDecoration(hintText: 'Название')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        TextButton(onPressed: () async {
          final name = ctrl.text.trim();
          if (name.isNotEmpty) {
            final id = await _db.insertAlbum(Album(name: name));
            await _loadAlbums();
            if (mounted) setState(() { _selectedAlbumId = id; _selectedAlbumName = name; });
          }
          if (mounted) Navigator.pop(context);
        }, child: const Text('Создать')),
      ],
    ));
  }

  @override
  void dispose() { _urlCtrl.dispose(); _titleCtrl.dispose(); super.dispose(); }
}
