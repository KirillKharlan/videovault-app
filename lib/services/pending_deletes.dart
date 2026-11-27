import 'package:flutter/material.dart';
import '../models/database.dart';
import 'video_delete_service.dart';

/// Удаление с возможностью отмены. Видео сразу пропадает из списков (id
/// попадает в [kHiddenVideoIds], а запросы к БД их не возвращают), внизу
/// 6 секунд висит плашка «Отменить». Если не отменили — файл, обложка и записи
/// удаляются по-настоящему. Если приложение закрыли в эти секунды, ничего не
/// удалено и видео просто вернётся в список — потерять файл по случайности нельзя.
class PendingDeletes {
  PendingDeletes._();

  static void schedule(BuildContext context, List<Video> videos, {VoidCallback? onChanged}) {
    final ids = [for (final v in videos) if (v.id != null) v.id!];
    if (ids.isEmpty) return;
    kHiddenVideoIds.addAll(ids);
    DBChangeNotifier.instance.bump();
    onChanged?.call();

    final messenger = ScaffoldMessenger.of(context);
    // Предыдущая плашка «Отменить» (если была) закрывается — то удаление завершится.
    messenger.removeCurrentSnackBar();
    final text = videos.length == 1
        ? 'Удалено: «${videos.first.title}»'
        : 'Удалено видео: ${videos.length}';
    messenger
        .showSnackBar(SnackBar(
          content: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(label: 'Отменить', onPressed: () {}),
        ))
        .closed
        .then((reason) async {
      if (reason == SnackBarClosedReason.action) {
        kHiddenVideoIds.removeAll(ids);
        DBChangeNotifier.instance.bump();
        onChanged?.call();
        return;
      }
      await deleteVideosCompletely(videos);
      kHiddenVideoIds.removeAll(ids);
    });
  }
}
