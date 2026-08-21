import 'package:flutter/services.dart';

/// Обёртка над нативным MethodChannel для Picture-in-Picture (см. MainActivity.kt).
/// Реализация полностью нативная (без сторонних пакетов) — по официальной
/// документации Android: https://developer.android.com/develop/ui/views/picture-in-picture
class PipService {
  PipService._internal();
  static final PipService instance = PipService._internal();

  static const _channel = MethodChannel('com.videovault/pip');

  bool _isInPip = false;
  bool get isInPip => _isInPip;

  final List<void Function(bool isInPip)> _listeners = [];

  // Колбэки для кнопок действий в PiP-окне и в уведомлении фонового
  // воспроизведения. Регистрируются ОДИН РАЗ в PlaybackManager (не в
  // PlayerScreen!) — иначе после сворачивания в фон и закрытия экрана
  // плеера кнопки в уведомлении перестанут работать.
  void Function()? onPlayPauseAction;
  void Function()? onSkipNextAction;
  void Function()? onForward10Action;
  void Function()? onStopAction;

  void addListener(void Function(bool isInPip) listener) {
    _listeners.add(listener);
    if (_listeners.length == 1) {
      _channel.setMethodCallHandler(_handleMethodCall);
    }
  }

  void removeListener(void Function(bool isInPip) listener) {
    _listeners.remove(listener);
    if (_listeners.isEmpty) {
      _channel.setMethodCallHandler(null);
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPipModeChanged':
        _isInPip = call.arguments as bool;
        for (final l in List.of(_listeners)) {
          l(_isInPip);
        }
        break;
      case 'pipAction_playPause':
        onPlayPauseAction?.call();
        break;
      case 'pipAction_skipNext':
        onSkipNextAction?.call();
        break;
      case 'pipAction_forward10':
        onForward10Action?.call();
        break;
      case 'pipAction_stop':
        onStopAction?.call();
        break;
    }
  }

  /// Обновляет состояние (играет/пауза, есть ли следующее видео, название) —
  /// влияет на панель действий системного PiP.
  Future<void> updateState({required bool isPlaying, required bool hasNext, String? title}) async {
    try {
      await _channel.invokeMethod('updatePipState', {
        'isPlaying': isPlaying,
        'hasNext': hasNext,
        if (title != null) 'title': title,
      });
    } catch (_) {
      // Не критично — просто иконки в панели действий не обновятся идеально.
    }
  }

  // ── Фоновое воспроизведение (foreground service + уведомление) ─────────

  Future<void> startBackgroundPlayback({required String title, required bool isPlaying}) async {
    try {
      await _channel.invokeMethod('startBackgroundService', {
        'title': title,
        'isPlaying': isPlaying,
      });
    } catch (_) {}
  }

  Future<void> updateBackgroundNotification({required String title, required bool isPlaying}) async {
    try {
      await _channel.invokeMethod('updateBackgroundNotification', {
        'title': title,
        'isPlaying': isPlaying,
      });
    } catch (_) {}
  }

  Future<void> stopBackgroundPlayback() async {
    try {
      await _channel.invokeMethod('stopBackgroundService');
    } catch (_) {}
  }

  Future<bool> isPipSupported() async {
    try {
      final result = await _channel.invokeMethod<bool>('isPipSupported');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Включает/выключает автоматический вход в PiP при сворачивании приложения.
  /// [aspectRatio] — ширина/высота видео (например 16/9 или 9/16 для вертикальных).
  Future<void> setAutoEnter(bool enabled, {double aspectRatio = 16 / 9}) async {
    final (num, den) = _ratioToFraction(aspectRatio);
    try {
      await _channel.invokeMethod('setAutoEnter', {
        'enabled': enabled,
        'aspectNumerator': num,
        'aspectDenominator': den,
      });
    } catch (_) {
      // Не критично — просто автовход не сработает на этом устройстве.
    }
  }

  /// Немедленный ручной вход в PiP (например, по нажатию кнопки в приложении).
  Future<void> enterPip({double aspectRatio = 16 / 9}) async {
    final (num, den) = _ratioToFraction(aspectRatio);
    try {
      await _channel.invokeMethod('enterPip', {
        'aspectNumerator': num,
        'aspectDenominator': den,
      });
    } catch (_) {
      // Игнорируем — не все устройства поддерживают PiP.
    }
  }

  /// Android принимает соотношение как целочисленную дробь (Rational), а не double.
  /// Приводим aspectRatio (например 1.777...) к приближённой дроби num/den.
  (int, int) _ratioToFraction(double ratio) {
    if (ratio <= 0 || ratio.isNaN || ratio.isInfinite) return (16, 9);
    const scale = 1000;
    var num = (ratio * scale).round();
    var den = scale;
    final g = _gcd(num, den);
    if (g > 0) { num ~/= g; den ~/= g; }
    // Android ограничивает разумные пределы соотношения (примерно 1:2.39 — 2.39:1)
    if (num / den > 2.39) { num = 239; den = 100; }
    if (num / den < 1 / 2.39) { num = 100; den = 239; }
    return (num, den);
  }

  int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);
}
