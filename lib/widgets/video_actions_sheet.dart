import 'package:flutter/material.dart';
import '../models/database.dart';
import '../services/video_edit_service.dart';
import 'safe_bottom_sheet.dart';

/// Меню действий по долгому нажатию на карточку видео: переименовать,
/// сменить/сбросить обложку. Общее для главного экрана и экрана альбомов.
Future<void> showVideoActionsSheet(
  BuildContext context,
  Video video, {
  required VoidCallback onChanged,
}) {
  final editor = VideoEditService();

  return showSafeModalBottomSheet(
    context: context,
    builder: (sheetCtx) => Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(video.title,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, color: Colors.white54)),
      ),
      ListTile(
        leading: const Icon(Icons.edit_outlined),
        title: const Text('Переименовать'),
        onTap: () async {
          Navigator.pop(sheetCtx);
          await _showRenameDialog(context, video, editor, onChanged);
        },
      ),
      ListTile(
        leading: const Icon(Icons.image_outlined),
        title: const Text('Изменить обложку'),
        onTap: () async {
          Navigator.pop(sheetCtx);
          final changed = await editor.changeCover(video);
          if (changed) onChanged();
        },
      ),
      if (video.thumbnailPath != null)
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('Сбросить обложку'),
          onTap: () async {
            Navigator.pop(sheetCtx);
            await editor.resetCover(video);
            onChanged();
          },
        ),
    ]),
  );
}

Future<void> _showRenameDialog(
  BuildContext context,
  Video video,
  VideoEditService editor,
  VoidCallback onChanged,
) async {
  final ctrl = TextEditingController(text: video.title);
  final newTitle = await showDialog<String>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('Переименовать видео'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: 1,
        decoration: const InputDecoration(hintText: 'Название видео'),
        onSubmitted: (v) => Navigator.pop(dialogCtx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Отмена')),
        TextButton(onPressed: () => Navigator.pop(dialogCtx, ctrl.text), child: const Text('Сохранить')),
      ],
    ),
  );
  if (newTitle == null || newTitle.trim().isEmpty || newTitle.trim() == video.title) return;
  await editor.renameVideo(video, newTitle);
  onChanged();
}
