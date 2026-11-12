import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PlaybackMode { video, music }

/// Как скачивать видео: через свой сервер, прямо на телефоне (yt-dlp внутри
/// приложения) или «авто» — сначала на телефоне, при неудаче через сервер.
enum DownloadMode { server, local, auto }

/// Глобальные настройки приложения — читается/меняется через одну вкладку
/// "Настройки" в нижнем меню, хранится в SharedPreferences (просто
/// ключ-значение, без отдельной таблицы в БД — это настройки приложения в
/// целом, а не данные про конкретное видео).
class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final instance = SettingsService._();

  static const _keyPlaybackMode = 'playback_mode';
  static const _keyDownloadMode = 'download_mode';

  PlaybackMode mode = PlaybackMode.video;
  DownloadMode downloadMode = DownloadMode.server;
  bool _loaded = false;

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
    final savedDownload = prefs.getString(_keyDownloadMode);
    downloadMode = DownloadMode.values.firstWhere(
      (m) => m.name == savedDownload,
      orElse: () => DownloadMode.server,
    );
    _loaded = true;
    notifyListeners();
  }

  Future<void> setDownloadMode(DownloadMode newMode) async {
    if (downloadMode == newMode) return;
    downloadMode = newMode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDownloadMode, newMode.name);
  }

  Future<void> setMode(PlaybackMode newMode) async {
    if (mode == newMode) return;
    mode = newMode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPlaybackMode, newMode == PlaybackMode.music ? 'music' : 'video');
  }
}
