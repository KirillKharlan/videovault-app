import 'package:flutter/foundation.dart';
import '../models/database.dart';
import 'download_service.dart';

/// Глобальное состояние текущей загрузки — не привязано к конкретному
/// экрану. DownloadScreen запускает загрузку через этот менеджер и НЕ
/// дожидается её (fire-and-forget), поэтому можно сразу уйти с экрана —
/// переключиться на другую вкладку, открыть плеер и т.д. Прогресс при
/// этом виден из любого места приложения, которое слушает этот менеджер
/// (см. полоску прогресса в MainScreen).
class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final instance = DownloadManager._();

  final _service = DownloadService();

  bool isDownloading = false;
  double progress = 0;
  String statusText = '';
  String? title;
  String? error;

  /// Запускает загрузку и СРАЗУ возвращает управление вызывающему коду —
  /// сам процесс продолжается в фоне независимо от того, ушёл пользователь
  /// с экрана или нет. [onDone]/[onError] вызываются, только если экран,
  /// который их передал, всё ещё смонтирован на момент завершения — это
  /// проверяет сам вызывающий код перед их вызовом.
  Future<void> startDownload({
    required String url,
    required String quality,
    int? albumId,
    String? customTitle,
    VideoInfo? info,
    void Function(Video video)? onDone,
    void Function(Object error)? onError,
  }) async {
    if (isDownloading) return; // уже что-то качаем — новый запуск игнорируем
    isDownloading = true;
    progress = 0;
    statusText = 'Запуск…';
    title = customTitle?.trim().isNotEmpty == true ? customTitle!.trim() : info?.title;
    error = null;
    notifyListeners();

    try {
      final video = await _service.download(
        url: url,
        quality: quality,
        albumId: albumId,
        customTitle: customTitle,
        info: info,
        onProgress: (p, step) {
          progress = p;
          statusText = step;
          notifyListeners();
        },
      );
      isDownloading = false;
      progress = 1;
      statusText = '';
      notifyListeners();
      onDone?.call(video);
    } catch (e) {
      isDownloading = false;
      error = e.toString();
      statusText = '';
      notifyListeners();
      onError?.call(e);
    }
  }

  void dismissError() {
    error = null;
    notifyListeners();
  }
}
