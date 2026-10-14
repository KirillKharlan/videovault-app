import 'package:flutter/material.dart';

/// Шапка режима множественного выбора видео: закрыть, счётчик, "выбрать всё"
/// и действия (удалить и т.п.). Заменяет обычную шапку экрана, пока идёт выбор.
class SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onClose;
  final VoidCallback onSelectAll;
  final List<Widget> actions;

  const SelectionBar({
    super.key,
    required this.count,
    required this.onClose,
    required this.onSelectAll,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.close), tooltip: 'Отменить выбор', onPressed: onClose),
        Expanded(
          child: Text('Выбрано: $count',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ),
        IconButton(
            icon: const Icon(Icons.select_all), tooltip: 'Выбрать всё', onPressed: onSelectAll),
        ...actions,
      ]),
    );
  }
}
