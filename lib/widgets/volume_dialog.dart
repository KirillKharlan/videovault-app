import 'package:flutter/material.dart';
import '../app_navigator.dart';
import '../services/playback_manager.dart';

/// Диалог с ползунком громкости. Открывается из меню ⋮ плеера chewie — оно
/// есть и в полноэкранном режиме, где обычный ползунок под видео недоступен.
/// Диалог показываем на корневом Navigator приложения (там же лежит и
/// полноэкранный маршрут chewie): контекст из меню плеера мог уже закрыться.
/// [ctx] — запасной вариант (в разных версиях chewie он может быть null).
void showVolumeDialog([BuildContext? ctx]) {
  final context = appNavigatorKey.currentContext ?? ctx;
  if (context == null) return;
  final mgr = PlaybackManager.instance;
  showDialog<void>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (_, setLocal) => AlertDialog(
        title: const Text('Громкость'),
        content: Row(children: [
          Icon(mgr.volume <= 0 ? Icons.volume_off : Icons.volume_up, size: 20),
          Expanded(
            child: Slider(
              value: mgr.volume.clamp(0.0, 1.0).toDouble(),
              min: 0,
              max: 1,
              onChanged: (v) {
                mgr.setVolume(v);
                setLocal(() {});
              },
            ),
          ),
          SizedBox(
            width: 40,
            child: Text('${(mgr.volume * 100).round()}%', textAlign: TextAlign.right),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx), child: const Text('Готово')),
        ],
      ),
    ),
  );
}
