import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PlaybackMode { video, music }

/// Глобальные настройки приложения — читается/меняется через одну вкладку
/// "Настройки" в нижнем меню, хранится в SharedPreferences (просто
/// ключ-значение, без отдельной таблицы в БД — это настройки приложения в
/// целом, а не данные про конкретное видео).
class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final instance = SettingsService._();

  static const _keyPlaybackMode = 'playback_mode';
  static const _keyDefaultQuality = 'default_quality';
  static const _keySponsorBlock = 'sponsorblock';
  static const _keyHomeSort = 'home_sort';

  PlaybackMode mode = PlaybackMode.video;
  bool _loaded = false;

  /// Качество по умолчанию: null — спрашивать при каждой загрузке, 'best' — лучшее
  /// доступное, иначе высота в пикселях ('1080'). Если такого качества у видео нет,
  /// показывается обычный выбор с пояснением.
  String? defaultQuality;

  /// Автопропуск рекламных вставок (SponsorBlock) для видео с YouTube.
  bool sponsorBlock = true;

  /// Сортировка списка видео на главном экране (имя значения HomeSort в home_screen.dart).
  String homeSort = 'newest';

  /// В режиме музыки позиция просмотра не запоминается и не предлагается —
  /// используется playback_manager.dart, чтобы полностью пропускать логику
  /// "продолжить с места остановки" (диапазоны повтора при этом не
  /// затрагиваются, это отдельная фича).
  bool get isMusicMode => mode == PlaybackMode.music;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_keyPlaybackMode);
    mode = saved == 'music' ? PlaybackMode.music : PlaybackMode.video;
    defaultQuality = prefs.getString(_keyDefaultQuality);
    sponsorBlock = prefs.getBool(_keySponsorBlock) ?? true;
    homeSort = prefs.getString(_keyHomeSort) ?? 'newest';
    _loaded = true;
    notifyListeners();
  }

  Future<void> setDefaultQuality(String? quality) async {
    defaultQuality = quality;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (quality == null) {
      await prefs.remove(_keyDefaultQuality);
    } else {
      await prefs.setString(_keyDefaultQuality, quality);
    }
  }

  Future<void> setHomeSort(String sort) async {
    homeSort = sort;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHomeSort, sort);
  }

  Future<void> setSponsorBlock(bool enabled) async {
    sponsorBlock = enabled;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySponsorBlock, enabled);
  }

  Future<void> setMode(PlaybackMode newMode) async {
    if (mode == newMode) return;
    mode = newMode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPlaybackMode, newMode == PlaybackMode.music ? 'music' : 'video');
  }
}
