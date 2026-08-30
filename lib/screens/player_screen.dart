import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:chewie/chewie.dart';
import '../models/database.dart';
import '../services/download_service.dart';
import '../services/pip_service.dart';
import '../services/media_export_service.dart';
import '../services/playback_manager.dart';
import '../widgets/safe_bottom_sheet.dart';

class PlayerScreen extends StatefulWidget {
  final Video video;
  final List<Video>? playlist;
  final int? initialIndex;

  const PlayerScreen({
    super.key,
    required this.video,
    this.playlist,
    this.initialIndex,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _db = AppDatabase();
  final _mgr = PlaybackManager.instance;

  bool _showVolumeSlider = false;
  double _volume = 1.0;
  bool _pipSupported = false;
  bool _isInPip = false;

  List<RepeatRange> _savedRanges = [];

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _mgr.addListener(_onManagerChanged);
    PipService.instance.addListener(_onPipModeChanged);
    // Колбэки Play/Pause/Next/+10s/Stop теперь регистрируются один раз
    // в PlaybackManager (см. его конструктор) — работают даже когда этот
    // экран закрыт (мини-плеер, системный PiP, фоновый звук).

    _checkPipSupport();
    _startPlayback();
  }

  Future<void> _startPlayback() async {
    await _mgr.loadAndPlay(widget.video, playlist: widget.playlist, index: widget.initialIndex);
    _mgr.controller?.setVolume(_volume);
    await _loadRanges();
  }

  Future<void> _loadRanges() async {
    final vid = _mgr.currentVideo?.id;
    if (vid == null) return;
    final ranges = await _db.getRangesForVideo(vid);
    if (mounted) setState(() => _savedRanges = ranges);
  }

  Future<void> _checkPipSupport() async {
    final supported = await PipService.instance.isPipSupported();
    if (mounted) setState(() => _pipSupported = supported);
    _syncAutoEnterPip();
  }

  bool? _lastAutoEnterState;
  double? _lastAutoEnterAspect;

  /// Включает авто-вход в PiP при сворачивании приложения (нажатие Home/
  /// системная кнопка "назад" на главный экран), пока играет обычное видео.
  /// В режиме фонового звука PiP-окно не нужно — звук и так продолжится
  /// через foreground-сервис, поэтому там авто-вход выключаем.
  void _syncAutoEnterPip() {
    if (!_pipSupported) return;
    final shouldAutoEnter = !_mgr.isBackgroundAudio;
    final aspect = _mgr.controller?.value.aspectRatio ?? (16 / 9);
    // _onManagerChanged дёргается на каждый тик плеера — не дёргаем канал
    // на нативную сторону, если состояние и так не поменялось.
    if (shouldAutoEnter == _lastAutoEnterState && aspect == _lastAutoEnterAspect) return;
    _lastAutoEnterState = shouldAutoEnter;
    _lastAutoEnterAspect = aspect;
    PipService.instance.setAutoEnter(shouldAutoEnter, aspectRatio: aspect);
  }

  void _onManagerChanged() {
    if (!mounted) return;
    setState(() {});
    // Видео сменилось (автопереход) — перечитываем список диапазонов для НОВОГО видео.
    _loadRanges();
    // Соотношение сторон могло смениться (портрет/пейзаж), либо включился/
    // выключился фоновый звук — держим авто-вход в PiP синхронизированным.
    _syncAutoEnterPip();
  }

  void _onPipModeChanged(bool isInPip) {
    if (mounted) setState(() => _isInPip = isInPip);
  }

  // ── Диапазоны повтора ────────────────────────────────────────────────────

  void _openRangeManagerSheet() {
    final dur = _mgr.controller?.value.duration ?? Duration.zero;
    if (dur == Duration.zero) return;

    showSafeModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Диапазоны повтора', style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 4),
            const Text('Сохранённые отрезки этого видео. Один можно сделать "по умолчанию" — он будет включаться автоматически при каждом запуске этого видео.',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 16),

            if (_savedRanges.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Пока нет сохранённых диапазонов', style: TextStyle(color: Colors.white38)),
              ),

            ..._savedRanges.map((r) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E2A),
                borderRadius: BorderRadius.circular(10),
                border: r.isDefault ? Border.all(color: const Color(0xFF7C5CFC)) : null,
              ),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(r.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                    if (r.isDefault) Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(Icons.star, size: 14, color: const Color(0xFF7C5CFC)),
                    ),
                  ]),
                  Text('${r.rangeLabel} · ${r.endBehavior == "loop" ? "зациклить" : "затем следующее"}',
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ])),
                IconButton(
                  icon: const Icon(Icons.play_circle_outline, size: 20, color: Colors.white70),
                  tooltip: 'Применить сейчас',
                  onPressed: () async {
                    await _mgr.applyRange(r);
                    if (mounted) Navigator.pop(ctx);
                  },
                ),
                IconButton(
                  icon: Icon(r.isDefault ? Icons.star : Icons.star_border, size: 20,
                      color: r.isDefault ? const Color(0xFF7C5CFC) : Colors.white70),
                  tooltip: 'Сделать по умолчанию',
                  onPressed: () async {
                    await _db.setDefaultRange(r.videoId, r.isDefault ? null : r.id);
                    await _loadRanges();
                    setSheetState(() {});
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
                  onPressed: () async {
                    await _db.deleteRange(r.id!);
                    await _loadRanges();
                    setSheetState(() {});
                  },
                ),
              ]),
            )),

            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _openCreateRangeSheet();
              },
              icon: const Icon(Icons.add),
              label: const Text('Создать новый диапазон'),
            ),
            if (_mgr.isLoopActive) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () { _mgr.clearRange(); Navigator.pop(ctx); },
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Выключить повтор'),
                style: TextButton.styleFrom(foregroundColor: Colors.white54),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  void _openCreateRangeSheet() {
    final dur = _mgr.controller?.value.duration ?? Duration.zero;
    if (dur == Duration.zero) return;

    double start = 0;
    double end = dur.inMilliseconds.toDouble();
    String behavior = 'loop';
    final labelCtrl = TextEditingController(text: 'Диапазон ${_savedRanges.length + 1}');
    bool setAsDefault = _savedRanges.isEmpty;

    showSafeModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Новый диапазон', style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 16),
            TextField(
              controller: labelCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            const SizedBox(height: 16),
            Text('${_fmt(Duration(milliseconds: start.round()))} — ${_fmt(Duration(milliseconds: end.round()))}',
                style: const TextStyle(color: Color(0xFF7C5CFC), fontWeight: FontWeight.bold)),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: const Color(0xFF7C5CFC),
                inactiveTrackColor: const Color(0xFF2A2A38),
                thumbColor: const Color(0xFF7C5CFC),
                rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: RangeSlider(
                values: RangeValues(start, end),
                min: 0, max: dur.inMilliseconds.toDouble(),
                onChanged: (v) => setSheetState(() { start = v.start; end = v.end; }),
              ),
            ),
            const SizedBox(height: 8),
            const Text('По окончании диапазона:', style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(child: ChoiceChip(
                label: const Text('Зациклить'),
                selected: behavior == 'loop',
                onSelected: (_) => setSheetState(() => behavior = 'loop'),
              )),
              const SizedBox(width: 8),
              Expanded(child: ChoiceChip(
                label: const Text('Следующее видео'),
                selected: behavior == 'next',
                onSelected: (_) => setSheetState(() => behavior = 'next'),
              )),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Checkbox(
                value: setAsDefault,
                activeColor: const Color(0xFF7C5CFC),
                onChanged: (v) => setSheetState(() => setAsDefault = v ?? false),
              ),
              const Expanded(child: Text('Включать автоматически при открытии этого видео',
                  style: TextStyle(color: Colors.white70, fontSize: 12))),
            ]),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () async {
                final videoId = _mgr.currentVideo?.id;
                if (videoId == null) return;
                final range = RepeatRange(
                  videoId: videoId,
                  label: labelCtrl.text.trim().isEmpty ? 'Без названия' : labelCtrl.text.trim(),
                  startMs: start.round(),
                  endMs: end.round(),
                  isDefault: setAsDefault,
                  endBehavior: behavior,
                );
                await _db.createRange(range);
                await _loadRanges();
                await _mgr.applyRange(range.copyWith());
                if (mounted) Navigator.pop(ctx);
              },
              child: const Text('Сохранить'),
            ),
          ]),
        ),
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _enterPipManually() async {
    final aspect = _mgr.controller?.value.aspectRatio ?? (16 / 9);
    await PipService.instance.enterPip(aspectRatio: aspect);
  }

  void _minimizeInApp() {
    _minimizing = true;
    _mgr.minimize();
    Navigator.of(context).pop();
  }

  Future<void> _enableBackgroundAudio() async {
    _minimizing = true;
    await _mgr.enableBackgroundAudio();
    if (mounted) Navigator.of(context).pop();
  }

  void _showExportOptions() {
    showSafeModalBottomSheet(
      context: context,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16),
            child: Text('Экспортировать', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
        ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('Видео (MP4) в галерею'),
          onTap: () { Navigator.pop(context); _exportVideo(toGallery: true); },
        ),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Видео (MP4) на устройство'),
          subtitle: const Text('Откроется системный диалог "Сохранить как"',
              style: TextStyle(fontSize: 11)),
          onTap: () { Navigator.pop(context); _exportVideo(toGallery: false); },
        ),
        ListTile(
          leading: const Icon(Icons.music_note_outlined),
          title: const Text('Конвертировать в MP3'),
          subtitle: const Text('Извлечёт звук и сохранит на устройство',
              style: TextStyle(fontSize: 11)),
          onTap: () { Navigator.pop(context); _exportAudio(); },
        ),
      ]),
    );
  }

  Future<void> _exportVideo({required bool toGallery}) async {
    final video = _mgr.currentVideo;
    if (video == null) return;
    _showExportProgress('Сохраняем видео…');
    try {
      if (toGallery) {
        await MediaExportService.instance.saveVideoToGallery(video.filePath);
      } else {
        final name = video.filePath.split(Platform.pathSeparator).last;
        await MediaExportService.instance.saveToDevice(video.filePath, fileName: name);
      }
      _closeExportProgress();
      _showSnack(toGallery ? 'Видео сохранено в галерею' : 'Видео сохранено на устройство');
    } catch (e) {
      _closeExportProgress();
      _showSnack('Не удалось экспортировать: $e', isError: true);
    }
  }

  Future<void> _exportAudio() async {
    final video = _mgr.currentVideo;
    if (video == null) return;
    _showExportProgress('Конвертируем в MP3…');
    try {
      final mp3Path = await MediaExportService.instance.convertToMp3(video.filePath);
      final name = mp3Path.split(Platform.pathSeparator).last;
      await MediaExportService.instance.saveToDevice(mp3Path, fileName: name);
      _closeExportProgress();
      _showSnack('MP3 сохранён на устройство');
    } catch (e) {
      _closeExportProgress();
      _showSnack('Не удалось сконвертировать: $e', isError: true);
    }
  }

  bool _exportDialogOpen = false;

  void _showExportProgress(String text) {
    _exportDialogOpen = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 16),
          Expanded(child: Text(text)),
        ]),
      ),
    );
  }

  void _closeExportProgress() {
    if (_exportDialogOpen && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      _exportDialogOpen = false;
    }
  }

  void _showSnack(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: isError ? Colors.redAccent : null,
    ));
  }

  void _showOptions() {
    showSafeModalBottomSheet(
      context: context,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.all(16),
            child: Text(_mgr.currentVideo?.title ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold))),
        if (_pipSupported)
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('Системный Picture-in-Picture'),
            onTap: () { Navigator.pop(context); _enterPipManually(); },
          ),
        ListTile(
          leading: const Icon(Icons.headphones),
          title: const Text('Свернуть, звук в фоне'),
          subtitle: const Text('Работает даже при полном закрытии приложения',
              style: TextStyle(fontSize: 11)),
          onTap: () { Navigator.pop(context); _enableBackgroundAudio(); },
        ),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Move to album'),
          onTap: () { Navigator.pop(context); _moveToAlbum(); },
        ),
        ListTile(
          leading: const Icon(Icons.download_outlined),
          title: const Text('Экспортировать'),
          subtitle: const Text('В галерею, на устройство, или в MP3',
              style: TextStyle(fontSize: 11)),
          onTap: () { Navigator.pop(context); _showExportOptions(); },
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('Video info'),
          onTap: () { Navigator.pop(context); _showInfo(); },
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
          title: const Text('Delete video', style: TextStyle(color: Colors.redAccent)),
          onTap: () { Navigator.pop(context); _deleteVideo(); },
        ),
      ]),
    );
  }

  void _moveToAlbum() async {
    final albums = await _db.getAlbums();
    final video = _mgr.currentVideo;
    if (!mounted || video == null) return;
    showSafeModalBottomSheet(
      context: context,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16),
            child: Text('Move to album', style: TextStyle(fontWeight: FontWeight.bold))),
        ListTile(leading: const Icon(Icons.folder_off_outlined), title: const Text('No album'),
            onTap: () async {
              await _db.updateVideo(video.copyWith(clearAlbum: true));
              if (mounted) Navigator.pop(context);
            }),
        ...albums.map((a) => ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(a.name),
          onTap: () async {
            await _db.updateVideo(video.copyWith(albumId: a.id));
            if (mounted) Navigator.pop(context);
          },
        )),
      ]),
    );
  }

  void _showInfo() {
    final v = _mgr.currentVideo;
    if (v == null) return;
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF16161E),
      title: const Text('Video info'),
      content: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoRow('Title', v.title),
          _infoRow('Platform', v.platform ?? 'unknown'),
          _infoRow('Duration', v.durationFormatted.isEmpty ? 'unknown' : v.durationFormatted),
          _infoRow('Size', v.fileSizeFormatted),
          if (v.sourceUrl != null) _infoRow('Source', v.sourceUrl!),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ));
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
      Text(value, style: const TextStyle(fontSize: 13)),
    ]),
  );

  void _deleteVideo() {
    final video = _mgr.currentVideo;
    if (video == null) return;
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF16161E),
      title: const Text('Delete video?'),
      content: const Text('This will permanently delete the file.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () async {
            Navigator.pop(context);
            await DownloadService().deleteVideoFile(video.filePath);
            await DownloadService().deleteThumbnail(video.thumbnailPath);
            await _db.deleteVideo(video.id!);
            await _mgr.close();
            if (mounted) Navigator.pop(context);
          },
          child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ));
  }

  IconData _volumeIcon() {
    if (_volume <= 0) return Icons.volume_off;
    if (_volume < 0.5) return Icons.volume_down;
    return Icons.volume_up;
  }

  bool _minimizing = false;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) return;
        // Если ушли через кнопку сворачивания — не останавливаем плеер,
        // он уже переведён в мини-режим менеджером. Во всех остальных
        // случаях (обычная стрелка назад, системный жест) — стоп.
        if (!_minimizing) {
          _mgr.close();
        }
      },
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    // Показываем минимальный UI, если система уже перевела нас в PiP —
    // рекомендация самой документации Android (мелкие виджеты неудобны
    // для тача в маленьком окошке, всё равно есть системные Actions).
    if (_isInPip) {
      final ctrl = _mgr.controller;
      return Scaffold(
        backgroundColor: Colors.black,
        body: ctrl == null
            ? const SizedBox.shrink()
            : Center(
                child: AspectRatio(
                  aspectRatio: ctrl.value.aspectRatio,
                  child: Chewie(controller: _mgr.chewieController!),
                ),
              ),
      );
    }

    final video = _mgr.currentVideo;
    final hasNext = _mgr.hasNext;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          // Title bar
          Row(children: [
            IconButton(icon: const Icon(Icons.arrow_back), color: Colors.white,
                onPressed: () => Navigator.of(context).pop()),
            Expanded(child: Text(video?.title ?? '', maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14))),
            IconButton(
              icon: Icon(_volumeIcon()), color: Colors.white,
              tooltip: 'Volume',
              onPressed: () => setState(() => _showVolumeSlider = !_showVolumeSlider),
            ),
            IconButton(
              icon: Icon(Icons.repeat, color: _mgr.isLoopActive ? const Color(0xFF7C5CFC) : Colors.white),
              tooltip: 'Repeat ranges',
              onPressed: _openRangeManagerSheet,
            ),
            IconButton(
              icon: const Icon(Icons.picture_in_picture_alt),
              color: Colors.white,
              tooltip: 'Свернуть в мини-окно (внутри приложения)',
              onPressed: _minimizeInApp,
            ),
            IconButton(icon: const Icon(Icons.more_vert), color: Colors.white,
                onPressed: _showOptions),
          ]),

          // Индикатор активного диапазона
          if (_mgr.isLoopActive)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(children: [
                const Icon(Icons.repeat, size: 14, color: Color(0xFF7C5CFC)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _mgr.activeRange != null
                        ? '${_mgr.activeRange!.label}: ${_mgr.activeRange!.rangeLabel}'
                        : 'Повтор: ${_fmt(_mgr.effectiveStart)} — ${_fmt(_mgr.effectiveEnd)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _openRangeManagerSheet,
                  child: const Text('Диапазоны', style: TextStyle(fontSize: 12)),
                ),
              ]),
            ),

          // Слайдер громкости
          if (_showVolumeSlider)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Icon(_volumeIcon(), color: Colors.white54, size: 18),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      activeTrackColor: const Color(0xFF7C5CFC),
                      inactiveTrackColor: const Color(0xFF2A2A38),
                      thumbColor: const Color(0xFF7C5CFC),
                      overlayColor: const Color(0x337C5CFC),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      value: _volume, min: 0, max: 1,
                      onChanged: (v) {
                        setState(() => _volume = v);
                        _mgr.controller?.setVolume(v);
                      },
                    ),
                  ),
                ),
                SizedBox(width: 32, child: Text('${(_volume * 100).round()}%',
                    style: const TextStyle(color: Colors.white54, fontSize: 11))),
              ]),
            ),

          // Player
          Expanded(child: _mgr.hasError
            ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.error_outline, size: 64, color: Colors.white38),
                SizedBox(height: 16),
                Text('Video file not found', style: TextStyle(color: Colors.white54)),
              ]))
            : (_mgr.chewieController == null || _mgr.isLoading)
              ? const Center(child: CircularProgressIndicator())
              : Chewie(controller: _mgr.chewieController!),
          ),

          if (hasNext && !_mgr.isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Expanded(
                  child: Text(
                    'Далее: ${_mgr.playlist![_mgr.currentIndex + 1].title}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next, color: Colors.white70),
                  onPressed: _mgr.playNext,
                  tooltip: 'Следующее видео',
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _mgr.removeListener(_onManagerChanged);
    PipService.instance.removeListener(_onPipModeChanged);
    // Колбэки действий (Play/Pause/Next/+10s/Stop) НЕ сбрасываем — они
    // постоянные, живут в PlaybackManager весь жизненный цикл приложения.
    if (_pipSupported && !_mgr.isBackgroundAudio) PipService.instance.setAutoEnter(false);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    // ВАЖНО: контроллер НЕ уничтожаем здесь — если пользователь свернул
    // видео в мини-плеер или включил фоновый звук, воспроизведение должно
    // продолжаться. Он будет закрыт явно через _mgr.close().
    super.dispose();
  }
}
