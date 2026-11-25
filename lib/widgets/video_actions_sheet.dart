import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cross_file/cross_file.dart';
import '../models/database.dart';
import '../services/video_delete_service.dart';
import '../services/video_edit_service.dart';
import 'safe_bottom_sheet.dart';
import 'video_albums_dialog.dart';

/// Меню действий по долгому нажатию на карточку видео: переименовать,
/// сменить/сбросить обложку, поделиться файлом, удалить. Общее для главного
/// экрана и экрана альбомов.
Future<void> showVideoActionsSheet(
  BuildContext context,
  Video video, {
  required VoidCallback onChanged,
  VoidCallback? onSelect, // если задан — в меню появляется пункт "Выбрать"
  // В плеере у видео уже есть своё «Удалить» (оно закрывает экран), поэтому
  // там пункт отключают.
  bool allowDelete = true,
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
      if (onSelect != null)
        ListTile(
          leading: const Icon(Icons.checklist_rtl),
          title: const Text('Выбрать'),
          subtitle: const Text('Отметить несколько видео, например чтобы удалить',
              style: TextStyle(fontSize: 11)),
          onTap: () {
            Navigator.pop(sheetCtx);
            onSelect();
          },
        ),
      ListTile(
        leading: const Icon(Icons.share_outlined),
        title: const Text('Поделиться видео'),
        subtitle: const Text(
          'Отправит сам файл (в WhatsApp/Telegram/итд), а не ссылку на источник',
          style: TextStyle(fontSize: 11),
        ),
        onTap: () async {
          Navigator.pop(sheetCtx);
          // Системное меню "Поделиться" с самим файлом — SharePlus сам
          // заворачивает путь в content:// (через свой FileProvider), так
          // что сторонним приложениям не нужен прямой доступ к файлу.
          await SharePlus.instance.share(
            ShareParams(files: [XFile(video.filePath)], text: video.title),
          );
        },
      ),
      ListTile(
        leading: const Icon(Icons.folder_copy_outlined),
        title: const Text('Альбомы'),
        subtitle: const Text('Можно добавить в несколько сразу',
            style: TextStyle(fontSize: 11)),
        onTap: () async {
          Navigator.pop(sheetCtx);
          await showVideoAlbumsDialog(context, video, onChanged: onChanged);
        },
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
      if (allowDelete)
        ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
          title: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
          subtitle: const Text('Файл будет удалён с устройства, видео пропадёт из всех альбомов',
              style: TextStyle(fontSize: 11)),
          onTap: () async {
            Navigator.pop(sheetCtx);
            await _confirmAndDelete(context, video, onChanged);
          },
        ),
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

/// Подтверждение и полное удаление одного видео (файл, обложка, записи в БД).
Future<void> _confirmAndDelete(BuildContext context, Video video, VoidCallback onChanged) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      title: const Text('Удалить видео?'),
      content: Text('«${video.title}»\n\nФайл будет удалён с устройства безвозвратно, '
          'видео пропадёт и из всех альбомов.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogCtx, false), child: const Text('Отмена')),
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          child: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await deleteVideosCompletely([video]);
  onChanged();
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
