import 'package:flutter/foundation.dart';
import '../api/api_client.dart';
import '../models/database.dart';
import 'download_service.dart';

enum DownloadJobStatus { queued, downloading, error }

/// Одна загрузка в очереди.
class DownloadJob {
  final int id;
  final String url;
  final String quality;
  final String? customTitle;
  final Future<VideoInfo?>? infoFuture;

  /// Альбом можно менять в любой момент до сохранения видео (см.
  /// DownloadService.albumIdResolver).
  int? albumId;
  String? albumName;

  VideoInfo? info;
  DownloadJobStatus status = DownloadJobStatus.queued;
  double progress = 0;
  String statusText = '';
  String? error;

  final void Function(Video video)? onDone;
  final void Function(Object error)? onError;

  DownloadJob({
    required this.id,
    required this.url,
    required this.quality,
    this.customTitle,
    this.infoFuture,
    this.info,
    this.albumId,
    this.albumName,
    this.onDone,
    this.onError,
  });

  String get title => customTitle ?? info?.title ?? url;
  bool get isActive => status == DownloadJobStatus.downloading;
}

/// Очередь загрузок. Качает по одной (бесплатный сервер и прокси не любят
/// параллельные тяжёлые загрузки), остальные ждут своей очереди. Живёт вне
/// экранов — прогресс виден отовсюду, а уйти с экрана можно в любой момент.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final instance = DownloadManager._();

  final _service = DownloadService();
  final List<DownloadJob> jobs = [];
  bool _running = false;
  int _nextId = 1;

  DownloadJob? get activeJob {
    for (final j in jobs) {
      if (j.isActive) return j;
    }
    return null;
  }

  int get pendingCount => jobs
      .where((j) => j.status == DownloadJobStatus.queued || j.isActive)
      .length;

  /// Вкладка "Очередь" нужна, только когда в ней есть что показывать
  /// сравнивая несколько загрузок: 2 и больше.
  bool get showQueueTab => jobs.length >= 2;

  // Удобные "одиночные" свойства для мест, где нужна только текущая загрузка
  // (плашка внизу, прогресс на экране загрузки).
  bool get isDownloading => activeJob != null;
  double get progress => activeJob?.progress ?? 0;
  String get statusText => activeJob?.statusText ?? '';
  VideoInfo? get info => activeJob?.info;
  String? get title => activeJob?.title;

  /// Ставит загрузку в очередь и сразу возвращает управление — поле ввода на
  /// экране можно очищать немедленно.
  DownloadJob enqueue({
    required String url,
    required String quality,
    int? albumId,
    String? albumName,
    String? customTitle,
    VideoInfo? info,
    Future<VideoInfo?>? infoFuture,
    void Function(Video video)? onDone,
    void Function(Object error)? onError,
  }) {
    final job = DownloadJob(
      id: _nextId++,
      url: url,
      quality: quality,
      customTitle: (customTitle?.trim().isNotEmpty == true) ? customTitle!.trim() : null,
      info: info,
      infoFuture: infoFuture,
      albumId: albumId,
      albumName: albumName,
      onDone: onDone,
      onError: onError,
    );
    // Инфо может прийти позже старта — подставляем, как только придёт (в
    // очереди появятся название и обложка, даже пока загрузка ждёт).
    infoFuture?.then((resolved) {
      if (resolved != null && jobs.contains(job)) {
        job.info = resolved;
        notifyListeners();
      }
    }).catchError((_) {});
    jobs.add(job);
    notifyListeners();
    _pump();
    return job;
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        DownloadJob? next;
        for (final j in jobs) {
          if (j.status == DownloadJobStatus.queued) {
            next = j;
            break;
          }
        }
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _run(DownloadJob job) async {
    job.status = DownloadJobStatus.downloading;
    job.progress = 0;
    job.statusText = 'Запуск…';
    job.error = null;
    notifyListeners();
    final Video video;
    try {
      video = await _service.download(
        url: job.url,
        quality: job.quality,
        albumId: job.albumId,
        albumIdResolver: () => job.albumId,
        customTitle: job.customTitle,
        info: job.info,
        infoFuture: job.infoFuture,
        onProgress: (p, step) {
          job.progress = p;
          job.statusText = step;
          notifyListeners();
        },
      );
    } catch (e) {
      job.status = DownloadJobStatus.error;
      job.error = e.toString();
      job.statusText = '';
      // Единственная оставшаяся (упавшая) загрузка в очереди не нужна: ошибку
      // уже показал экран загрузки через onError, а вкладка очереди без пары
      // не показывается.
      _pruneLoneError();
      notifyListeners();
      job.onError?.call(e);
      return;
    }
    // Колбэк вызываем вне try: ошибка в нём не должна выглядеть как провал
    // самой загрузки.
    jobs.remove(job);
    notifyListeners();
    job.onDone?.call(video);
  }

  void _pruneLoneError() {
    if (jobs.length == 1 && jobs.first.status == DownloadJobStatus.error) {
      jobs.clear();
    }
  }

  void setAlbum(DownloadJob job, int? albumId, String? albumName) {
    job.albumId = albumId;
    job.albumName = albumName;
    notifyListeners();
  }

  /// Повторить упавшую загрузку — встаёт в конец очереди.
  void retry(DownloadJob job) {
    if (job.status != DownloadJobStatus.error) return;
    jobs.remove(job);
    job.status = DownloadJobStatus.queued;
    job.error = null;
    job.progress = 0;
    jobs.add(job);
    notifyListeners();
    _pump();
  }

  /// Убрать из очереди ожидающую или упавшую загрузку. Уже идущую остановить
  /// нельзя — сервер продолжает работу, отмены в API нет.
  void remove(DownloadJob job) {
    if (job.isActive) return;
    jobs.remove(job);
    _pruneLoneError();
    notifyListeners();
  }
}
