import 'dart:async';
import 'package:flutter/services.dart';

/// Foreground-сервис Android на время скачивания (DownloadForegroundService.kt):
/// не даёт системе убить приложение, пока оно свёрнуто, держит CPU после
/// блокировки экрана и показывает уведомление с прогрессом и кнопкой «Отменить».
///
/// Загрузки идут по очереди, поэтому используется счётчик: сервис запускается
/// с первой загрузкой и останавливается, когда активных не осталось (с короткой
/// задержкой, чтобы между двумя подряд идущими загрузками уведомление не мигало).
class DownloadForeground {
  DownloadForeground._();

  static const MethodChannel _channel = MethodChannel('com.videovault/dlservice');

  /// Нажали «Отменить» в уведомлении — подключает DownloadManager.
  static void Function()? onCancel;

  static int _active = 0;
  static Timer? _stopTimer;
  static bool _running = false;
  static bool _handlerSet = false;
  static int _lastPercent = -2;
  static DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'cancel') onCancel?.call();
      return null;
    });
  }

  static Future<void> _send(String title, String text, int percent) async {
    try {
      await _channel.invokeMethod('start', {'title': title, 'text': text, 'percent': percent});
      _running = true;
    } catch (_) {
      // Сервис не запустился (например, ограничения системы) — скачивание
      // продолжится как раньше, просто без защиты от фона.
    }
  }

  /// Начало загрузки.
  static Future<void> begin({String title = 'Загрузка', String text = 'Запуск…'}) async {
    _ensureHandler();
    _active++;
    _stopTimer?.cancel();
    _stopTimer = null;
    _lastPercent = -2;
    await _send(title, text, -1);
  }

  /// Обновление прогресса (не чаще раза в ~0,7 с или при смене процента).
  static void update({required String title, required int percent, String? text}) {
    if (_active <= 0) return;
    final now = DateTime.now();
    if (percent == _lastPercent && now.difference(_lastSent).inMilliseconds < 700) return;
    if (now.difference(_lastSent).inMilliseconds < 700 && (percent - _lastPercent).abs() < 2) return;
    _lastPercent = percent;
    _lastSent = now;
    _send(title, text ?? '$percent%', percent);
  }

  /// Конец загрузки (успешный, с ошибкой или отменённой).
  static void end() {
    _active--;
    if (_active > 0) return;
    _active = 0;
    _stopTimer?.cancel();
    _stopTimer = Timer(const Duration(milliseconds: 1500), () async {
      if (_active > 0) return;
      try {
        await _channel.invokeMethod('stop');
      } catch (_) {}
      _running = false;
    });
  }

  static bool get isRunning => _running;
}
