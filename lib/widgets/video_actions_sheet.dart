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
      _LetterboxSwitch(video: video, editor: editor, onChanged: onChanged),
    ]),
  );
}

/// Отдельный виджет вместо StatefulBuilder с локальной переменной — value
/// свитча должен быть завязан на РЕАЛЬНО мутируемое состояние, а не на
/// захваченное поле video.letterboxLandscape (оно не меняется после
/// построения sheet, поэтому переключатель просто отскакивал назад).
class _LetterboxSwitch extends StatefulWidget {
  final Video video;
  final VideoEditService editor;
  final VoidCallback onChanged;
  const _LetterboxSwitch({required this.video, required this.editor, required this.onChanged});

  @override
  State<_LetterboxSwitch> createState() => _LetterboxSwitchState();
}

class _LetterboxSwitchState extends State<_LetterboxSwitch> {
  late bool _value = widget.video.letterboxLandscape;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.crop_landscape_outlined),
      title: const Text('Горизонтальный просмотр'),
      subtitle: const Text(
        'Для вертикальных видео — показывать в широкой рамке с полосами по бокам',
        style: TextStyle(fontSize: 11),
      ),
      value: _value,
      onChanged: (v) async {
        setState(() => _value = v);
        await widget.editor.setLetterbox(widget.video, v);
        widget.onChanged();
      },
    );
  }
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
