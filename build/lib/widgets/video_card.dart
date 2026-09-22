import 'dart:io';
import 'package:flutter/material.dart';
import '../models/database.dart';

class VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  // ── Режим выбора (для мультивыбора при добавлении в альбом) ────────────
  final bool selectionMode;
  final bool selected;
  final int? selectionOrder; // порядковый номер выбора (1, 2, 3...)

  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
    this.selectionOrder,
  });

  @override
  Widget build(BuildContext context) {
    final purple = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF16161E),
          borderRadius: BorderRadius.circular(12),
          border: selected ? Border.all(color: purple, width: 2.5) : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Thumbnail
          Expanded(
            child: Stack(fit: StackFit.expand, children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: _buildThumbnail(),
              ),
              // Затемнение при выборе
              if (selectionMode && selected)
                Container(color: purple.withOpacity(0.25)),

              // Play icon overlay (скрыт в режиме выбора)
              if (!selectionMode)
                const Center(child: Icon(Icons.play_circle_fill,
                    size: 40, color: Colors.white70)),

              // Duration badge
              if (video.duration > 0)
                Positioned(bottom: 6, right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.75),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(video.durationFormatted,
                        style: const TextStyle(color: Colors.white, fontSize: 10)),
                  )),

              // Platform badge
              if (video.platform != null && !selectionMode)
                Positioned(top: 6, left: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C5CFC).withOpacity(0.85),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(video.platform!.toUpperCase(),
                        style: const TextStyle(color: Colors.white,
                            fontSize: 9, fontWeight: FontWeight.bold)),
                  )),

              // Selection checkmark / order number
              if (selectionMode)
                Positioned(top: 6, left: 6,
                  child: Container(
                    width: 26, height: 26,
                    decoration: BoxDecoration(
                      color: selected ? purple : Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white70, width: 1.2),
                    ),
                    alignment: Alignment.center,
                    child: selected
                        ? Text('${selectionOrder ?? ''}',
                            style: const TextStyle(color: Colors.white,
                                fontSize: 12, fontWeight: FontWeight.bold))
                        : null,
                  )),
            ]),
          ),
          // Title
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(video.title,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.white)),
          ),
        ]),
      ),
    );
  }

  Widget _buildThumbnail() {
    final thumb = video.thumbnailPath;
    if (thumb != null && File(thumb).existsSync()) {
      return Image.file(File(thumb), fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder());
    }
    return _placeholder();
  }

  Widget _placeholder() => Container(
    color: const Color(0xFF1E1E2A),
    child: const Center(child: Icon(Icons.video_file, size: 40, color: Colors.white24)),
  );
}
