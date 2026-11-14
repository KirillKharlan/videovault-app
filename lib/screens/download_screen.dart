import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../api/api_client.dart';
import '../models/database.dart';
import '../services/download_manager.dart';
import '../services/local_ytdlp_service.dart';
import '../services/settings_service.dart';
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
  final _api        = ApiClient();
  final _db         = AppDatabase();

  // Инфо о последней введённой ссылке: если пользователь закрыл выбор качества
  // и нажал «Скачать» ещё раз, повторно не запрашиваем.
  VideoInfo? _cachedInfo;
  String? _cachedInfoUrl;
  int?    _selectedAlbumId;
  String? _selectedAlbumName;
  List<Album> _albums = [];

  bool   _fetchingInfo = false;
  String _fetchError   = '';
  String _downloadError = '';

  @override
  void initState() {
    super.initState();
    _loadAlbums();
    DownloadManager.instance.addListener(_onManagerChanged);
    if (widget.initialUrl != null) {
      _urlCtrl.text = widget.initialUrl!;
      widget.onUrlConsumed?.call();
    }
  }

  void _onManagerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadAlbums() async {
    final albums = await _db.getAlbums();
    if (mounted) setState(() => _albums = albums);
  }

  /// Запрашивает инфо о видео и обновляет форму. Возвращает полученную инфо
  /// (или null при ошибке) — это нужно, чтобы _download() мог передать этот
  /// же Future в DownloadService и запустить скачивание ПАРАЛЛЕЛЬНО, не
  /// дожидаясь ответа.
  /// Инфо о видео тем же способом, каким будет идти скачивание (настройка
  /// «Способ скачивания»): на телефоне — локальным yt-dlp, через сервер — как
  /// раньше, «авто» — сначала телефон, при ошибке сервер.
  Future<VideoInfo> _loadInfo(String url, {bool refresh = false}) async {
    final mode = SettingsService.instance.downloadMode;
    if (mode == DownloadMode.server) return _api.fetchInfo(url, refresh: refresh);
    try {
      return await LocalYtdlpService.instance.fetchInfo(url);
    } catch (e) {
      if (mode == DownloadMode.local) rethrow;
      return _api.fetchInfo(url, refresh: refresh);
    }
  }

  static String _modeLabel(DownloadMode m) {
    switch (m) {
      case DownloadMode.server: return 'Через сервер';
      case DownloadMode.local:  return 'На телефоне (экспериментально)';
      case DownloadMode.auto:   return 'Авто: сначала на телефоне';
    }
  }

  void _pickDownloadMode() {
    final settings = SettingsService.instance;
    showSafeModalBottomSheet(context: context,
      builder: (_) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(padding: EdgeInsets.all(16),
              child: Text('Способ скачивания', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          ...DownloadMode.values.map((m) => ListTile(
            title: Text(_modeLabel(m)),
            trailing: settings.downloadMode == m
                ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
            onTap: () {
              settings.setDownloadMode(m);
              setState(() {});
              Navigator.pop(context);
            },
          )),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text('Список качеств зависит от способа скачивания и запрашивается '
                'при нажатии «Скачать».',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
          ),
        ]),
      ),
    );
  }

  /// Инфо о видео для выбора качества: из кэша (та же ссылка) либо запрос.
  /// null — ошибка (текст в _fetchError) или ссылку успели поменять.
  Future<VideoInfo?> _obtainInfo(String url) async {
    if (_cachedInfoUrl == url && _cachedInfo != null) return _cachedInfo;
    setState(() { _fetchingInfo = true; _fetchError = ''; _downloadError = ''; });
    try {
      final info = await _loadInfo(url);
      if (!mounted) return null;
      setState(() => _fetchingInfo = false);
      if (_urlCtrl.text.trim() != url) return null; // ссылку поменяли, пока шёл запрос
      _cachedInfo = info;
      _cachedInfoUrl = url;
      return info;
    } catch (e) {
      if (mounted) setState(() { _fetchingInfo = false; _fetchError = '❌ $e'; });
      return null;
    }
  }

  /// Кнопка «Скачать»: получает инфо о видео, показывает выбор качества и
  /// только после выбора ставит загрузку в очередь DownloadManager. Форма
  /// СРАЗУ освобождается: можно вставлять следующую ссылку, не дожидаясь
  /// конца этой. Альбом остаётся выбранным (удобно качать пачкой в один
  /// альбом); у каждой загрузки в очереди его можно поменять отдельно.
  Future<void> _download() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty || _fetchingInfo) return;

    // Это видео уже есть в библиотеке? Предупреждаем до того, как тратить
    // трафик на повторное скачивание той же самой копии.
    final existing = await _db.findVideoBySourceUrl(url);
    if (existing != null && mounted) {
      final again = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('Уже в библиотеке'),
          content: Text('Это видео уже скачано:\n«${existing.title}»\n\nСкачать ещё одну копию?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('Скачать ещё раз'),
            ),
          ],
        ),
      );
      if (again != true) return;
    }

    // 1. Узнаём, в каких качествах доступно видео
    final info = await _obtainInfo(url);
    if (info == null || !mounted) return;

    // 2. Пользователь выбирает качество (и при желании меняет название)
    final choice = await _pickQualityForDownload(url, info);
    if (choice == null || !mounted) return; // закрыли, ничего не выбрав

    // 3. Скачивание в выбранном качестве
    DownloadManager.instance.enqueue(
      url: url,
      quality: choice.quality,
      albumId: _selectedAlbumId,
      albumName: _selectedAlbumName,
      customTitle: choice.title,
      info: choice.info,
      infoFuture: null,
      onDone: (video) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('✅ Сохранено: ${video.title}')));
      },
      onError: (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ $e')));
        setState(() { _downloadError = '$e'; });
      },
    );

    setState(() {
      _fetchError = '';
      _downloadError = '';
      _cachedInfo = null;
      _cachedInfoUrl = null;
    });
    _urlCtrl.clear();
  }

  /// Окно выбора качества. Показывает превью и название (его можно изменить),
  /// список доступных качеств с оценкой размера и кнопку «Обновить список».
  /// Возвращает выбор или null, если окно закрыли.
  Future<_QualityChoice?> _pickQualityForDownload(String url, VideoInfo initial) {
    var info = initial;
    var title = initial.title;
    var refreshing = false;
    String? refreshError;
    return showSafeModalBottomSheet<_QualityChoice>(
      context: context,
      builder: (sheetCtx) => StatefulBuilder(builder: (ctx, setSheet) {
        final purple = Theme.of(ctx).colorScheme.primary;
        final count = info.qualities.length;
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(children: [
              if (info.thumbnail != null)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: info.thumbnail!,
                      width: 100, height: 60, fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                          width: 100, height: 60, color: const Color(0xFF1E1E2A),
                          child: const Icon(Icons.video_file, color: Colors.white38)),
                    ),
                  ),
                ),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Row(children: [
                  _badge(info.platform.toUpperCase(), purple),
                  const SizedBox(width: 8),
                  Text(info.durationFormatted,
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ]),
              ])),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: 'Изменить название',
                onPressed: () async {
                  final t = await _askTitle(ctx, title);
                  if (t != null && ctx.mounted) setSheet(() => title = t);
                },
              ),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('Выберите качество — загрузка начнётся сразу',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          for (var i = 0; i < count; i++)
            ListTile(
              title: Text(info.qualityLabel(info.qualities[i]) +
                  (i == 0 && count > 1 ? ' · лучшее' : '')),
              subtitle: info.qualitySizeLabel(info.qualities[i]) == null
                  ? null
                  : Text(info.qualitySizeLabel(info.qualities[i])!),
              trailing: Icon(Icons.download, color: purple),
              onTap: () => Navigator.pop(
                sheetCtx,
                _QualityChoice(
                  quality: info.qualities[i],
                  info: info,
                  // Название передаём, только если его меняли.
                  title: title.trim().isNotEmpty && title.trim() != initial.title
                      ? title.trim()
                      : null,
                ),
              ),
            ),
          const Divider(height: 1),
          ListTile(
            leading: refreshing
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            title: const Text('Обновить список качеств'),
            subtitle: const Text('Если нужного качества нет — запросить заново'),
            onTap: refreshing
                ? null
                : () async {
                    setSheet(() { refreshing = true; refreshError = null; });
                    try {
                      final fresh = await _loadInfo(url, refresh: true);
                      _cachedInfo = fresh;
                      _cachedInfoUrl = url;
                      if (!ctx.mounted) return;
                      setSheet(() { info = fresh; refreshing = false; });
                    } catch (e) {
                      if (!ctx.mounted) return;
                      setSheet(() { refreshing = false; refreshError = '$e'; });
                    }
                  },
          ),
          if (refreshError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('❌ $refreshError',
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
        ]);
      }),
    );
  }

  /// Диалог изменения названия. null — отмена или пустое название.
  Future<String?> _askTitle(BuildContext ctx, String current) {
    final ctrl = TextEditingController(text: current);
    return showDialog<String>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: const Color(0xFF16161E),
        title: const Text('Название'),
        content: TextField(controller: ctrl, autofocus: true, maxLines: 3, minLines: 1),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Отмена')),
          TextButton(
            onPressed: () {
              final t = ctrl.text.trim();
              Navigator.pop(dialogCtx, t.isEmpty ? null : t);
            },
            child: const Text('Готово'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.primary;
    final mgr = DownloadManager.instance;
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
                  onSubmitted: (_) => _download(),
                )),
              ]),
            ]),

            // Опции
            const SizedBox(height: 16),
            _card(children: [
              const Text('Настройки', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 12),

              _optionRow(Icons.cloud_download_outlined, 'Способ скачивания',
                  _modeLabel(SettingsService.instance.downloadMode), _pickDownloadMode),

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

            // Прогресс — встроен прямо в форму, ничего не прячет и не
            // подменяет собой остальной экран.
            if (mgr.isDownloading) ...[
              const SizedBox(height: 20),
              Text(mgr.title ?? 'Загрузка…',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: mgr.progress > 0 ? mgr.progress : null,
                backgroundColor: const Color(0xFF1E1E2A),
                valueColor: AlwaysStoppedAnimation(purple),
              ),
              const SizedBox(height: 8),
              Text(mgr.statusText, style: const TextStyle(color: Colors.white54, fontSize: 13)),
              if (mgr.pendingCount > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('В очереди ещё: ${mgr.pendingCount - 1}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12)),
                ),
            ],

            if (_fetchError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_fetchError,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),

            // Ошибка последней попытки скачивания — остаётся на экране
            // (не только мелькает снэкбаром), пока не начнётся новая попытка.
            if (_downloadError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('❌ $_downloadError',
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),

            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _fetchingInfo ? null : _download,
              icon: _fetchingInfo
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download),
              label: Text(_fetchingInfo
                  ? 'Получение информации…'
                  : (mgr.isDownloading ? 'Добавить в очередь' : 'Скачать')),
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
  void dispose() {
    DownloadManager.instance.removeListener(_onManagerChanged);
    _urlCtrl.dispose();
    super.dispose();
  }
}

/// Результат окна выбора качества.
class _QualityChoice {
  final String quality;
  final VideoInfo info;
  final String? title; // null — название не меняли
  _QualityChoice({required this.quality, required this.info, this.title});
}
