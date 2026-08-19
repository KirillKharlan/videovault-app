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
    if (call.method == 'onPipModeChanged') {
      _isInPip = call.arguments as bool;
      for (final l in List.of(_listeners)) {
        l(_isInPip);
      }
    }
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
