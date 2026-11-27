import 'package:flutter/material.dart';
import '../models/album_style.dart';

/// Результат диалога создания/редактирования альбома.
class AlbumEditResult {
  final String name;
  final String icon;
  final int color;
  const AlbumEditResult({required this.name, required this.icon, required this.color});
}

/// Диалог создания или правки альбома: название, значок и цвет значка.
/// [initialName]/[initialIcon]/[initialColor] — текущие значения при правке.
/// Возвращает null, если диалог закрыли без сохранения или название пустое.
Future<AlbumEditResult?> showAlbumEditDialog(
  BuildContext context, {
  required String title,
  String initialName = '',
  String? initialIcon,
  int? initialColor,
}) {
  final ctrl = TextEditingController(text: initialName);
  var icon = kAlbumIcons.containsKey(initialIcon) ? initialIcon! : 'folder';
  var color = initialColor ?? kDefaultAlbumColor;

  return showDialog<AlbumEditResult>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final accent = Color(color);
        return AlertDialog(
          backgroundColor: const Color(0xFF16161E),
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: ctrl,
                autofocus: initialName.isEmpty,
                decoration: const InputDecoration(hintText: 'Название альбома'),
              ),
              const SizedBox(height: 16),
              const Text('Иконка', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final entry in kAlbumIcons.entries)
                  GestureDetector(
                    onTap: () => setLocal(() => icon = entry.key),
                    child: Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: icon == entry.key ? accent.withOpacity(0.25) : const Color(0xFF1E1E2A),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: icon == entry.key ? accent : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Icon(entry.value, color: icon == entry.key ? accent : Colors.white54),
                    ),
                  ),
              ]),
              const SizedBox(height: 16),
              const Text('Цвет', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final c in kAlbumColors)
                  GestureDetector(
                    onTap: () => setLocal(() => color = c),
                    child: Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color == c ? Colors.white : Colors.transparent,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Отмена')),
            TextButton(
              onPressed: () {
                final name = ctrl.text.trim();
                if (name.isEmpty) return; // пустое название не сохраняем
                Navigator.pop(dialogCtx, AlbumEditResult(name: name, icon: icon, color: color));
              },
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    ),
  );
}
