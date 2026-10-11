import 'package:flutter/material.dart';
import '../models/database.dart';

/// Диалог "В каких альбомах состоит видео": галочки по всем альбомам, можно
/// отметить сразу несколько. Сохранение приводит набор альбомов видео ровно
/// к отмеченному (снятая галочка = убрать из альбома, видео при этом
/// остаётся в общей библиотеке и в остальных альбомах).
Future<void> showVideoAlbumsDialog(
  BuildContext context,
  Video video, {
  VoidCallback? onChanged,
}) async {
  final id = video.id;
  if (id == null) return;
  final db = AppDatabase();
  final albums = await db.getAlbums();
  final selected = await db.getAlbumIdsForVideo(id);
  if (!context.mounted) return;

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Альбомы'),
        content: SizedBox(
          width: double.maxFinite,
          child: albums.isEmpty
              ? const Text('Альбомов пока нет — создайте альбом на вкладке Albums.')
              : ListView(
                  shrinkWrap: true,
                  children: albums.map((a) => CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: selected.contains(a.id),
                        title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onChanged: (v) => setDialogState(() {
                          if (v == true) {
                            selected.add(a.id!);
                          } else {
                            selected.remove(a.id);
                          }
                        }),
                      )).toList(),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Отмена'),
          ),
          if (albums.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('Сохранить'),
            ),
        ],
      ),
    ),
  );

  if (saved == true) {
    await db.setVideoAlbums(id, selected);
    onChanged?.call();
  }
}
