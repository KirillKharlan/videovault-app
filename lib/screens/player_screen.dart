import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import '../models/database.dart';
import '../services/download_service.dart';

class PlayerScreen extends StatefulWidget {
  final Video video;
  const PlayerScreen({super.key, required this.video});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _vpCtrl;
  ChewieController? _chewieCtrl;
  bool _error = false;
  final _db = AppDatabase();

  @override
  void initState() {
    super.initState();
    // Landscape + portrait
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final file = File(widget.video.filePath);
    if (!await file.exists()) {
      setState(() => _error = true);
      return;
    }
    _vpCtrl = VideoPlayerController.file(file);
    await _vpCtrl!.initialize();
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
    if (mounted) setState(() {});
  }

  void _showOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16161E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.all(16),
            child: Text(widget.video.title, maxLines: 2, overflow: TextOverflow.ellipsis,
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
        const SizedBox(height: 16),
      ]),
    );
  }

  void _moveToAlbum() async {
    final albums = await _db.getAlbums();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16161E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(16),
            child: Text('Move to album', style: TextStyle(fontWeight: FontWeight.bold))),
        ListTile(leading: const Icon(Icons.folder_off_outlined), title: const Text('No album'),
            onTap: () async {
              await _db.updateVideo(Video(
                id: widget.video.id, title: widget.video.title,
                filePath: widget.video.filePath, albumId: null,
                sourceUrl: widget.video.sourceUrl, platform: widget.video.platform,
                duration: widget.video.duration, fileSize: widget.video.fileSize,
              ));
              if (mounted) Navigator.pop(context);
            }),
        ...albums.map((a) => ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(a.name),
          onTap: () async {
            await _db.updateVideo(Video(
              id: widget.video.id, title: widget.video.title,
              filePath: widget.video.filePath, albumId: a.id,
              sourceUrl: widget.video.sourceUrl, platform: widget.video.platform,
              duration: widget.video.duration, fileSize: widget.video.fileSize,
            ));
            if (mounted) Navigator.pop(context);
          },
        )),
        const SizedBox(height: 16),
      ]),
    );
  }

  void _showInfo() {
    final v = widget.video;
    showDialog(context: context, builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF16161E),
      title: const Text('Video info'),
      content: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoRow('Title', v.title),
          _infoRow('Platform', v.platform ?? 'unknown'),
          _infoRow('Duration', v.durationFormatted),
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
            await DownloadService().deleteVideoFile(widget.video.filePath);
            await _db.deleteVideo(widget.video.id!);
            if (mounted) Navigator.pop(context);
          },
          child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ));
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
            Expanded(child: Text(widget.video.title, maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14))),
            IconButton(icon: const Icon(Icons.more_vert), color: Colors.white,
                onPressed: _showOptions),
          ]),
          // Player
          Expanded(child: _error
            ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.error_outline, size: 64, color: Colors.white38),
                SizedBox(height: 16),
                Text('Video file not found', style: TextStyle(color: Colors.white54)),
              ]))
            : _chewieCtrl == null
              ? const Center(child: CircularProgressIndicator())
              : Chewie(controller: _chewieCtrl!),
          ),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _chewieCtrl?.dispose();
    _vpCtrl?.dispose();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }
}
