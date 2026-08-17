import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_pip/index.dart' hide VideoPlayerController;
import 'package:chewie/chewie.dart';
import '../models/database.dart';
import '../services/download_service.dart';
import '../widgets/safe_bottom_sheet.dart';

class PlayerScreen extends StatefulWidget {
  final Video video;

  /// Список видео для автоперехода "следующее" (весь список "Videos" или
  /// список конкретного альбома — передаётся с того экрана, откуда открыли
  /// плеер). Если не передан — автоперехода не будет.
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
  VideoPlayerController? _vpCtrl;
  ChewieController? _chewieCtrl;
  bool _error = false;
  bool _isLoadingNext = false;
  final _db = AppDatabase();

  late Video _currentVideo = widget.video;
  int _currentIndex = 0;

  bool _showVolumeSlider = false;
  double _volume = 1.0;

  // ── Повтор (loop) + настраиваемый диапазон A-B ─────────────────────────
  // Session-only: сбрасывается при переходе на другое видео или выходе
  // с экрана — нигде не сохраняется в БД специально по требованию.
  bool _loopEnabled = false;
  Duration? _repeatStart;
  Duration? _repeatEnd;
  bool _endHandled = false;

  bool _pipSupported = false;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex ?? 0;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _checkPipSupport();
    _initPlayer(_currentVideo);
  }

  Future<void> _checkPipSupport() async {
    try {
      final supported = await VideoPlayerPip.isPipSupported();
      if (mounted) setState(() => _pipSupported = supported);
    } catch (_) {
      if (mounted) setState(() => _pipSupported = false);
    }
  }

  bool get _hasNext =>
      widget.playlist != null && _currentIndex < widget.playlist!.length - 1;

  Future<void> _initPlayer(Video video) async {
    final file = File(video.filePath);
    if (!await file.exists()) {
      setState(() => _error = true);
      return;
    }

    // Сброс состояния повтора при загрузке любого видео (нового или первого) —
    // настройки повтора всегда только "для текущего видео этой сессии".
    _loopEnabled = false;
    _repeatStart = null;
    _repeatEnd = null;
    _endHandled = false;

    _chewieCtrl?.dispose();
    await _vpCtrl?.dispose();

    _vpCtrl = VideoPlayerController.file(file);
    await _vpCtrl!.initialize();
    await _vpCtrl!.setVolume(_volume);
    _vpCtrl!.addListener(_onPositionChanged);

    _chewieCtrl = ChewieController(
      videoPlayerController: _vpCtrl!,
      autoPlay: true,
      looping: false,
      allowFullScreen: true,
      allowMuting: true,
      showControlsOnInitialize: true,
      materialProgressColors: ChewieProgressColors(
        playedColor: const Color(0xFF7C5CFC),
        handleColor: const Color(0xFF7C5CFC),
        backgroundColor: const Color(0xFF2A2A38),
        bufferedColor: const Color(0xFF3D2E80),
      ),
    );
    if (mounted) setState(() { _error = false; _isLoadingNext = false; });
  }

  void _onPositionChanged() {
    final ctrl = _vpCtrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    final pos = ctrl.value.position;
    final dur = ctrl.value.duration;

    if (_loopEnabled) {
      final end = _repeatEnd ?? dur;
      if (pos >= end - const Duration(milliseconds: 150)) {
        ctrl.seekTo(_repeatStart ?? Duration.zero);
        if (!ctrl.value.isPlaying) ctrl.play();
      }
      return;
    }

    // Без повтора — естественное завершение видео → переход к следующему.
    if (!_endHandled && dur > Duration.zero &&
        pos >= dur - const Duration(milliseconds: 300) &&
        !ctrl.value.isPlaying) {
      _endHandled = true;
      if (_hasNext) _playNext();
    }
  }

  Future<void> _playNext() async {
    if (!_hasNext || _isLoadingNext) return;
    setState(() { _isLoadingNext = true; _currentIndex++; });
    _currentVideo = widget.playlist![_currentIndex];
    await _initPlayer(_currentVideo);
  }

  void _toggleLoop() {
    setState(() {
      _loopEnabled = !_loopEnabled;
      if (!_loopEnabled) { _repeatStart = null; _repeatEnd = null; }
    });
  }

  void _openRepeatRangeSheet() {
    final dur = _vpCtrl?.value.duration ?? Duration.zero;
    if (dur == Duration.zero) return;
    double start = (_repeatStart ?? Duration.zero).inMilliseconds.toDouble();
    double end = (_repeatEnd ?? dur).inMilliseconds.toDouble();

    showSafeModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Диапазон повтора', style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 4),
            const Text('Видео будет повторяться только в этом отрезке',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 20),
            Text(
              '${_fmt(Duration(milliseconds: start.round()))} — ${_fmt(Duration(milliseconds: end.round()))}',
              style: const TextStyle(color: Color(0xFF7C5CFC), fontSize: 15, fontWeight: FontWeight.bold),
            ),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: const Color(0xFF7C5CFC),
                inactiveTrackColor: const Color(0xFF2A2A38),
                thumbColor: const Color(0xFF7C5CFC),
                rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: RangeSlider(
                values: RangeValues(start, end),
                min: 0,
                max: dur.inMilliseconds.toDouble(),
                onChanged: (values) {
                  setSheetState(() { start = values.start; end = values.end; });
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(
                onPressed: () {
                  setSheetState(() { start = 0; end = dur.inMilliseconds.toDouble(); });
                },
                child: const Text('Сбросить'),
              )),
              const SizedBox(width: 12),
              Expanded(child: ElevatedButton(
                onPressed: () {
                  setState(() {
                    _repeatStart = Duration(milliseconds: start.round());
                    _repeatEnd = Duration(milliseconds: end.round());
                    _loopEnabled = true;
                  });
                  Navigator.pop(ctx);
                },
                child: const Text('Применить'),
              )),
            ]),
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

  Future<void> _enterPip() async {
    final ctrl = _vpCtrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    final aspect = ctrl.value.aspectRatio;
    const width = 300;
    final height = (width / aspect).round();
    try {
      await ctrl.enterPipMode(width: width, height: height);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PiP недоступен на этом устройстве: $e')));
      }
    }
  }

  void _showOptions() {
    showSafeModalBottomSheet(
      context: context,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.all(16),
            child: Text(_currentVideo.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold))),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Move to album'),
          onTap: () { Navigator.pop(context); _moveToAlbum(); },
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
    if (!mounted) return;
    showSafeModalBottomSheet(
      context: context,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16),
            child: Text('Move to album', style: TextStyle(fontWeight: FontWeight.bold))),
        ListTile(leading: const Icon(Icons.folder_off_outlined), title: const Text('No album'),
            onTap: () async {
              await _db.updateVideo(_currentVideo.copyWith(clearAlbum: true));
              if (mounted) Navigator.pop(context);
            }),
        ...albums.map((a) => ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(a.name),
          onTap: () async {
            await _db.updateVideo(_currentVideo.copyWith(albumId: a.id));
            if (mounted) Navigator.pop(context);
          },
        )),
      ]),
    );
  }

  void _showInfo() {
    final v = _currentVideo;
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
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF16161E),
      title: const Text('Delete video?'),
      content: const Text('This will permanently delete the file.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: () async {
            Navigator.pop(context);
            await DownloadService().deleteVideoFile(_currentVideo.filePath);
            await DownloadService().deleteThumbnail(_currentVideo.thumbnailPath);
            await _db.deleteVideo(_currentVideo.id!);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          // Title bar
          Row(children: [
            IconButton(icon: const Icon(Icons.arrow_back), color: Colors.white,
                onPressed: () => Navigator.pop(context)),
            Expanded(child: Text(_currentVideo.title, maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14))),
            IconButton(
              icon: Icon(_volumeIcon()), color: Colors.white,
              tooltip: 'Volume',
              onPressed: () => setState(() => _showVolumeSlider = !_showVolumeSlider),
            ),
            IconButton(
              icon: Icon(Icons.repeat, color: _loopEnabled ? const Color(0xFF7C5CFC) : Colors.white),
              tooltip: 'Repeat',
              onPressed: _toggleLoop,
            ),
            if (_pipSupported)
              IconButton(
                icon: const Icon(Icons.picture_in_picture_alt),
                color: Colors.white,
                tooltip: 'Picture-in-picture',
                onPressed: _enterPip,
              ),
            IconButton(icon: const Icon(Icons.more_vert), color: Colors.white,
                onPressed: _showOptions),
          ]),

          // Индикатор повтора + доступ к настройке диапазона
          if (_loopEnabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(children: [
                const Icon(Icons.repeat, size: 14, color: Color(0xFF7C5CFC)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _repeatStart != null || _repeatEnd != null
                        ? 'Повтор: ${_fmt(_repeatStart ?? Duration.zero)} — ${_fmt(_repeatEnd ?? (_vpCtrl?.value.duration ?? Duration.zero))}'
                        : 'Повтор всего видео',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _openRepeatRangeSheet,
                  child: const Text('Задать диапазон', style: TextStyle(fontSize: 12)),
                ),
              ]),
            ),

          // Слайдер громкости (тонкая настройка, как на YouTube)
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
                        _vpCtrl?.setVolume(v);
                      },
                    ),
                  ),
                ),
                SizedBox(width: 32, child: Text('${(_volume * 100).round()}%',
                    style: const TextStyle(color: Colors.white54, fontSize: 11))),
              ]),
            ),

          // Player
          Expanded(child: _error
            ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.error_outline, size: 64, color: Colors.white38),
                SizedBox(height: 16),
                Text('Video file not found', style: TextStyle(color: Colors.white54)),
              ]))
            : (_chewieCtrl == null || _isLoadingNext)
              ? const Center(child: CircularProgressIndicator())
              : Chewie(controller: _chewieCtrl!),
          ),

          // Индикатор "следующее видео" (когда есть плейлист)
          if (_hasNext && !_isLoadingNext)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Expanded(
                  child: Text(
                    'Далее: ${widget.playlist![_currentIndex + 1].title}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next, color: Colors.white70),
                  onPressed: _playNext,
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
    _vpCtrl?.removeListener(_onPositionChanged);
    _chewieCtrl?.dispose();
    _vpCtrl?.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }
}
