import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/database.dart';
import '../widgets/volume_dialog.dart';
import 'pip_service.dart';
import 'settings_service.dart';

/// Центральное хранилище состояния воспроизведения — живёт ВНЕ PlayerScreen,
/// поэтому видео продолжает играть при сворачивании плеера (мини-окно внутри
/// приложения, системный PiP, или полностью в фоне со звуком).
///
/// ВАЖНО: колбэки для кнопок (PiP Actions, уведомление фонового
/// воспроизведения) регистрируются здесь ОДИН РАЗ на весь жизненный цикл
/// приложения — не в PlayerScreen. Иначе после сворачивания и закрытия
/// экрана плеера (dispose PlayerScreen) кнопки в уведомлении/PiP переставали
/// бы работать, хотя видео продолжает играть.
/// Когда у видео сохранены И диапазон повтора, И позиция остановки —
/// PlaybackManager сам не решает, что применить, а выставляет это поле,
/// чтобы PlayerScreen спросил пользователя. По умолчанию (пока не спросили)
/// уже применён диапазон — он безопаснее как дефолт, но пользователь может
/// переключиться на позицию.
class ResumeChoice {
  final Duration position;
  final RepeatRange range;
  ResumeChoice(this.position, this.range);
}

class PlaybackManager extends ChangeNotifier {
  PlaybackManager._internal() {
    PipService.instance.onPlayPauseAction = togglePlayPause;
    PipService.instance.onSkipNextAction = playNext;
    PipService.instance.onForward10Action = () => skipForward(const Duration(seconds: 10));
    PipService.instance.onStopAction = () => close();
    WidgetsBinding.instance.addObserver(_LifecycleBridge(this));
  }
  static final PlaybackManager instance = PlaybackManager._internal();

  final _db = AppDatabase();

  VideoPlayerController? controller;
  ChewieController? chewieController;
  Video? currentVideo;
  List<Video>? playlist;
  int currentIndex = 0;

  bool isMinimized = false;
  /// Полностью в фоне со звуком (foreground service + уведомление) —
  /// отдельно от isMinimized, поскольку в этом режиме приложение может быть
  /// вообще не открыто (пользователь на рабочем столе/в другом приложении).
  bool isBackgroundAudio = false;
  bool isLoading = false;
  bool hasError = false;

  // ── Диапазон повтора (активный сейчас — из сохранённых или "на лету") ───
  RepeatRange? activeRange;
  bool adhocLoop = false;
  Duration? adhocStart;
  Duration? adhocEnd;
  bool _endHandled = false;

  bool _wakelockOn = false;

  // ── Громкость (общая для видео, аудио-движка и ползунка в полноэкранном режиме) ──
  double volume = 1.0;

  // ── Фоновый звук ─────────────────────────────────────────────────────
  // video_player на Android привязан к поверхности (Surface): когда приложение
  // сворачивается, поверхность уничтожается и плагин останавливает/пересоздаёт
  // плеер — звук обрывается, даже если процесс держит foreground-сервис.
  // Поэтому в режиме «звук в фоне» при сворачивании звук передаётся
  // отдельному аудиоплееру (just_audio — ему поверхность не нужна), а при
  // возврате в приложение — обратно в видео с того же места. Пропуски,
  // диапазон повтора и переход к следующему видео работают в обоих режимах
  // через один и тот же _tick().
  AudioPlayer? _audio;
  bool _audioActive = false;
  bool _audioSwitching = false;
  StreamSubscription<Duration>? _audioPosSub;
  StreamSubscription<PlayerState>? _audioStateSub;
  // Аудиоплеер заранее открывает файл текущего видео (пока приложение ещё на экране),
  // иначе при сворачивании звук пропадал бы на время загрузки файла.
  int? _preparedAudioVideoId;
  Future<void>? _preparing;
  bool _playingAtLeave = false;
  Duration _positionAtLeave = Duration.zero;
  int? _videoControllerVideoId;

  // ── Продолжить с места остановки ────────────────────────────────────
  // Порог, ниже/выше которого не считаем нужным ни сохранять, ни
  // предлагать резюме — самое начало или практически конец видео.
  static const _resumeThreshold = Duration(seconds: 5);
  DateTime? _lastPositionSaveTime;
  /// Не null только когда у видео есть И диапазон, И позиция остановки —
  /// PlayerScreen должен спросить пользователя и, если выбрана позиция,
  /// заново перемотать (по умолчанию уже применён диапазон при загрузке).
  ResumeChoice? pendingResumeChoice;

  // ── Пропуски (реклама, заставки) ───────────────────────────────────────
  /// Участки текущего видео, которые проматываются автоматически. Работают
  /// и с диапазоном повтора, и без него.
  List<SkipSegment> skips = [];
  /// Общий выключатель на время сессии: можно временно посмотреть всё как
  /// есть, не удаляя пропуски.
  bool skipsEnabled = true;
  /// Начало пропуска, которое уже отметили, но конец ещё нет (плеер в этот
  /// момент показывает панель "Конец здесь").
  Duration? pendingSkipStart;
  DateTime? _lastSkipAt;

  // ── Таймер сна ───────────────────────────────────────────────────────
  Duration? sleepTimerRemaining;
  Timer? _sleepTimer;
  DateTime? _sleepTimerEndsAt;

  bool get hasNext => playlist != null && currentIndex < playlist!.length - 1;
  bool get isPlaying => _audioActive
      ? ((_audio?.playing ?? false) &&
          _audio?.processingState != ProcessingState.completed)
      : (controller?.value.isPlaying ?? false);

  bool get isLoopActive => activeRange != null || adhocLoop;
  Duration get effectiveStart =>
      activeRange?.start ?? adhocStart ?? Duration.zero;
  Duration get effectiveEnd =>
      activeRange?.end ?? adhocEnd ?? (controller?.value.duration ?? Duration.zero);
  String get endBehavior => activeRange?.endBehavior ?? 'loop';

  /// [startAt]/[autoPlay]/[force] нужны только при возврате из фонового звука
  /// (см. _returnToVideo): создать видео-плеер заново с места, где остановился звук.
  Future<void> loadAndPlay(Video video, {
    List<Video>? playlist,
    int? index,
    Duration? startAt,
    bool autoPlay = true,
    bool force = false,
  }) async {
    if (!force && currentVideo?.id == video.id && controller != null && !hasError) {
      isMinimized = false;
      notifyListeners();
      return;
    }

    // Сейчас звук ведёт аудио-движок (приложение в фоне) — следующий ролик
    // тоже грузим в него, не трогая видео-плеер.
    if (_audioActive && !force) {
      await _loadInAudioEngine(video, playlist: playlist, index: index);
      return;
    }

    await _disposeCurrent();
    currentVideo = video;
    this.playlist = playlist;
    currentIndex = index ?? 0;
    isLoading = true;
    hasError = false;
    isMinimized = false;
    notifyListeners();

    final file = File(video.filePath);
    if (!await file.exists()) {
      isLoading = false;
      hasError = true;
      notifyListeners();
      return;
    }

    controller = VideoPlayerController.file(file);
    await controller!.initialize();
    await controller!.setVolume(volume);
    _videoControllerVideoId = video.id;
    controller!.addListener(_onTick);

    activeRange = await _db.getDefaultRange(video.id!);
    skips = await _db.getSkipsForVideo(video.id!);
    pendingSkipStart = null;
    _lastSkipAt = null;
    adhocLoop = false;
    adhocStart = null;
    adhocEnd = null;
    _endHandled = false;
    pendingResumeChoice = null;

    final dur = controller!.value.duration;
    // В режиме музыки "продолжить с места остановки" вообще не действует —
    // ни сохранение, ни предложение резюме. Диапазон повтора (если задан)
    // при этом по-прежнему применяется, это отдельная фича, её не трогаем.
    final saved = SettingsService.instance.isMusicMode
        ? Duration.zero
        : Duration(milliseconds: video.lastPositionMs);
    final hasSavedPosition = saved > _resumeThreshold && saved < dur - _resumeThreshold;

    if (startAt != null) {
      // Возврат из фонового звука: продолжаем ровно с места, где остановился звук.
      await controller!.seekTo(startAt);
    } else if (activeRange != null && hasSavedPosition) {
      // И диапазон, и сохранённая позиция — не решаем молча, спрашиваем
      // пользователя (см. PlayerScreen). Пока не спросили — диапазон как
      // безопасный дефолт (уже подразумевает осознанный выбор пользователя).
      pendingResumeChoice = ResumeChoice(saved, activeRange!);
      await controller!.seekTo(activeRange!.start);
    } else if (activeRange != null) {
      // Сохранённый диапазон повтора — это осознанный выбор пользователя
      // (например, "пропускать заставку"), он приоритетнее обычного
      // "продолжить с места остановки".
      await controller!.seekTo(activeRange!.start);
    } else if (hasSavedPosition) {
      await controller!.seekTo(saved);
    }

    chewieController = ChewieController(
      videoPlayerController: controller!,
      autoPlay: autoPlay,
      looping: false,
      allowFullScreen: true,
      allowMuting: true,
      // Пункт «Громкость» в меню ⋮ плеера — работает и в полноэкранном режиме,
      // где наш обычный ползунок под видео не виден (там только вкл/выкл звука).
      additionalOptions: (context) => <OptionItem>[
        OptionItem(
          // Параметр необязательный: в разных версиях chewie onTap либо без
          // аргументов, либо получает BuildContext — так подходит и то, и другое.
          onTap: ([BuildContext? ctx]) => showVolumeDialog(ctx),
          iconData: Icons.volume_up,
          title: 'Громкость',
        ),
      ],
      showControlsOnInitialize: true,
      materialProgressColors: ChewieProgressColors(
        playedColor: const Color(0xFF7C5CFC),
        handleColor: const Color(0xFF7C5CFC),
        backgroundColor: const Color(0xFF2A2A38),
        bufferedColor: const Color(0xFF3D2E80),
      ),
    );

    isLoading = false;
    notifyListeners();
    _syncPipState();
  }

  void _onTick() {
    final ctrl = controller;
    if (_audioActive || ctrl == null || !ctrl.value.isInitialized) return;
    // Системная кнопка mute в chewie меняет громкость контроллера — держим
    // ползунок в соответствии с ней.
    if (ctrl.value.volume != volume) volume = ctrl.value.volume;
    _tick(ctrl.value.position, ctrl.value.duration, ctrl.value.isPlaying,
        seek: (d) => ctrl.seekTo(d), play: () => ctrl.play());
  }

  /// Один и тот же разбор позиции для видео-плеера и фонового аудио-движка:
  /// пропуски, диапазон повтора, конец видео → следующее.
  void _tick(Duration pos, Duration dur, bool playing, {
    required Future<void> Function(Duration) seek,
    required Future<void> Function() play,
  }) {
    // Пропуск обрабатываем ДО логики диапазона/конца видео: если сейчас
    // перемотали, остальное в этот тик не нужно — позиция уже другая.
    if (_applySkips(seek, pos, dur)) {
      notifyListeners();
      return;
    }

    if (isLoopActive) {
      final end = effectiveEnd == Duration.zero ? dur : effectiveEnd;
      if (pos >= end - const Duration(milliseconds: 150)) {
        if (endBehavior == 'next' && hasNext) {
          playNext();
        } else if (endBehavior == 'next' && !hasNext &&
            playlist != null && playlist!.length > 1) {
          // "Затем следующее" на ПОСЛЕДНЕМ видео плейлиста/альбома — следующего
          // нет, по кругу переходим на первое (та же логика, что и для видео
          // без диапазона повтора).
          playFirst();
        } else {
          seek(effectiveStart);
          if (!playing) play();
        }
      }
      return;
    }

    if (!_endHandled && dur > Duration.zero &&
        pos >= dur - const Duration(milliseconds: 300) &&
        !playing) {
      _endHandled = true;
      // Досмотрено до конца — сохранённая позиция теряет смысл (нечего
      // "продолжать"), сбрасываем её, а не оставляем зависшей у самого
      // конца или на месте, где остановились в прошлый раз до этого.
      final finishedVideo = currentVideo;
      if (finishedVideo?.id != null) {
        _db.updateLastPosition(finishedVideo!.id!, 0);
      }
      if (hasNext) {
        playNext();
      } else if (playlist != null && playlist!.length > 1) {
        // Последнее видео в плейлисте/альбоме закончилось. isLoopActive
        // уже проверен выше (return сработал бы раньше) — значит на этом
        // видео повторение не включено, и по кругу переходим на первое.
        playFirst();
      }
    }

    _syncWakelock();
    _syncPipState();
    _maybeSavePosition(pos, dur);
  }

  /// Если позиция попала в пропуск — перематывает на его конец. Возвращает
  /// true, если перемотка была. Соседние/пересекающиеся пропуски склеиваются
  /// (перематываем сразу за последний из цепочки).
  bool _applySkips(Future<void> Function(Duration) seek, Duration pos, Duration dur) {
    if (!skipsEnabled || skips.isEmpty) return false;
    // Пауза после прошлого пропуска — чтобы не зациклиться, пока перемотка
    // ещё не отразилась в position.
    final now = DateTime.now();
    if (_lastSkipAt != null &&
        now.difference(_lastSkipAt!) < const Duration(milliseconds: 800)) {
      return false;
    }
    Duration? target;
    for (final s in skips) {
      if (pos >= s.start && pos < s.end && (target == null || s.end > target)) {
        target = s.end;
      }
    }
    if (target == null) return false;
    var extended = true;
    while (extended) {
      extended = false;
      for (final s in skips) {
        if (target! >= s.start && target < s.end) {
          target = s.end;
          extended = true;
        }
      }
    }
    _lastSkipAt = now;
    final Duration to = target!;
    // Пропуск до самого конца — не уходим за длительность, иначе плеер
    // может не отработать завершение видео штатно.
    final safeEnd = dur - const Duration(milliseconds: 200);
    seek(to >= dur && safeEnd > Duration.zero ? safeEnd : to);
    return true;
  }

  /// Добавляет пропуск [start]–[end]. Возвращает текст ошибки или null, если
  /// всё сохранено.
  Future<String?> addSkip(Duration start, Duration end) async {
    final video = currentVideo;
    final ctrl = controller;
    if (video?.id == null || ctrl == null) return 'Видео не загружено';
    final dur = ctrl.value.duration;
    final clampedEnd = end > dur ? dur : end;
    if (clampedEnd - start < const Duration(milliseconds: 500)) {
      return 'Пропуск слишком короткий — конец должен быть позже начала';
    }
    await _db.createSkip(SkipSegment(
      videoId: video!.id!,
      startMs: start.inMilliseconds,
      endMs: clampedEnd.inMilliseconds,
    ));
    skips = await _db.getSkipsForVideo(video.id!);
    notifyListeners();
    return null;
  }

  Future<void> removeSkip(SkipSegment skip) async {
    final video = currentVideo;
    if (skip.id == null || video?.id == null) return;
    await _db.deleteSkip(skip.id!);
    skips = await _db.getSkipsForVideo(video!.id!);
    notifyListeners();
  }

  void setSkipsEnabled(bool enabled) {
    skipsEnabled = enabled;
    notifyListeners();
  }

  void startMarkingSkip() {
    final ctrl = controller;
    if (ctrl == null) return;
    pendingSkipStart = ctrl.value.position;
    notifyListeners();
  }

  void cancelMarkingSkip() {
    pendingSkipStart = null;
    notifyListeners();
  }

  /// Сохраняет позицию не чаще раза в 5 секунд — на каждый тик было бы
  /// слишком часто для записи на диск. Не сохраняем совсем в начале/конце
  /// ролика — нет смысла запоминать "продолжить с 0:02" или с последней секунды.
  void _maybeSavePosition(Duration pos, Duration dur) {
    if (SettingsService.instance.isMusicMode) return;
    final video = currentVideo;
    if (video?.id == null) return;
    if (pos <= _resumeThreshold || pos >= dur - _resumeThreshold) return;
    final now = DateTime.now();
    if (_lastPositionSaveTime != null &&
        now.difference(_lastPositionSaveTime!) < const Duration(seconds: 5)) {
      return;
    }
    _lastPositionSaveTime = now;
    _db.updateLastPosition(video!.id!, pos.inMilliseconds);
  }

  Future<void> playNext() async {
    if (!hasNext) return;
    currentIndex++;
    final next = playlist![currentIndex];
    // Сохраняем режимы сворачивания при автопереходе — если играли в фоне,
    // следующее видео должно так же продолжить играть в фоне, а не всплыть
    // на экран/сброситься.
    final wasBackgroundAudio = isBackgroundAudio;
    final wasMinimized = isMinimized;
    await loadAndPlay(next, playlist: playlist, index: currentIndex);
    if (wasBackgroundAudio) {
      isBackgroundAudio = true;
      _preparing = _prepareAudio(next);
      await PipService.instance.updateBackgroundNotification(
          title: next.title, isPlaying: true);
    }
    if (wasMinimized) {
      isMinimized = true;
      notifyListeners();
    }
  }

  Future<void> playFirst() async {
    if (playlist == null || playlist!.isEmpty) return;
    final first = playlist![0];
    // Сохраняем режимы сворачивания при автопереходе — так же, как playNext.
    final wasBackgroundAudio = isBackgroundAudio;
    final wasMinimized = isMinimized;
    await loadAndPlay(first, playlist: playlist, index: 0);
    if (wasBackgroundAudio) {
      isBackgroundAudio = true;
      _preparing = _prepareAudio(first);
      await PipService.instance.updateBackgroundNotification(
          title: first.title, isPlaying: true);
    }
    if (wasMinimized) {
      isMinimized = true;
      notifyListeners();
    }
  }

  void togglePlayPause() {
    if (_audioActive) {
      final audio = _audio;
      if (audio == null) return;
      if (audio.playing) {
        audio.pause();
        final video = currentVideo;
        if (!SettingsService.instance.isMusicMode && video?.id != null) {
          _db.updateLastPosition(video!.id!, audio.position.inMilliseconds);
        }
      } else {
        audio.play();
      }
      notifyListeners();
      _syncPipState();
      return;
    }
    if (controller == null) return;
    if (controller!.value.isPlaying) {
      controller!.pause();
      if (!SettingsService.instance.isMusicMode) {
        final video = currentVideo;
        final pos = controller!.value.position;
        if (video?.id != null) _db.updateLastPosition(video!.id!, pos.inMilliseconds);
      }
    } else {
      controller!.play();
    }
    notifyListeners();
    _syncWakelock();
    _syncPipState();
  }

  /// Держит экран включённым, пока видео реально играет (не только в
  /// режиме "фоновый звук") — иначе при просмотре без касаний экрана
  /// срабатывает обычная блокировка телефона и видео/звук останавливаются.
  /// Не связан с CPU-wakelock фонового сервиса — это отдельная защита
  /// (см. BackgroundPlaybackService), нужная именно для игры с потухшим
  /// экраном, где держать экран включённым как раз не нужно.
  void _syncWakelock() {
    final shouldBeOn = isPlaying;
    if (shouldBeOn == _wakelockOn) return;
    _wakelockOn = shouldBeOn;
    if (shouldBeOn) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  void skipForward(Duration amount) {
    if (_audioActive) {
      final audio = _audio;
      if (audio == null) return;
      final dur = audio.duration ?? Duration.zero;
      final target = audio.position + amount;
      audio.seek(dur > Duration.zero && target > dur ? dur : target);
      return;
    }
    final ctrl = controller;
    if (ctrl == null) return;
    final target = ctrl.value.position + amount;
    final dur = ctrl.value.duration;
    ctrl.seekTo(target > dur ? dur : target);
  }

  void _syncPipState() {
    final title = currentVideo?.title ?? 'VideoVault';
    final aspect = controller?.value.aspectRatio;
    PipService.instance.updateState(
      isPlaying: isPlaying, hasNext: hasNext, title: title, aspectRatio: aspect);
    if (isBackgroundAudio) {
      PipService.instance.updateBackgroundNotification(title: title, isPlaying: isPlaying);
    }
  }

  // ── Диапазоны повтора: применение "на лету" (без сохранения) ───────────

  void setAdhocRange(Duration start, Duration end) {
    activeRange = null;
    adhocLoop = true;
    adhocStart = start;
    adhocEnd = end;
    notifyListeners();
  }

  void clearRange() {
    activeRange = null;
    adhocLoop = false;
    adhocStart = null;
    adhocEnd = null;
    notifyListeners();
  }

  Future<void> applyRange(RepeatRange range) async {
    activeRange = range;
    adhocLoop = false;
    adhocStart = null;
    adhocEnd = null;
    await controller?.seekTo(range.start);
    notifyListeners();
  }

  // ── Мини-плеер внутри приложения ─────────────────────────────────────

  void minimize() {
    if (controller == null) return;
    isMinimized = true;
    notifyListeners();
  }

  void restore() {
    isMinimized = false;
    notifyListeners();
  }

  // ── Полностью фоновое воспроизведение (со звуком, без окна) ────────────
  //
  // Запускает foreground-сервис с уведомлением. У сервиса теперь ДВЕ задачи
  // (см. BackgroundPlaybackService.kt): не дать системе убить процесс, И
  // не дать системе усыпить CPU после выключения экрана через свой
  // собственный PARTIAL_WAKE_LOCK — именно это раньше не давало звуку
  // играть за пределами приложения. Экранный WakelockPlus (_syncWakelock)
  // тут ни при чём: он держит ЭКРАН включённым, а в фоне экран как раз
  // должен иметь возможность потухнуть.

  Future<void> enableBackgroundAudio() async {
    if (controller == null || currentVideo == null) return;
    isBackgroundAudio = true;
    isMinimized = false; // мини-окно не нужно — работаем полностью в фоне
    _preparing = _prepareAudio(currentVideo!);
    notifyListeners();
    await PipService.instance.startBackgroundPlayback(
      title: currentVideo!.title,
      isPlaying: isPlaying,
    );
  }

  Future<void> disableBackgroundAudio() async {
    if (!isBackgroundAudio) return;
    isBackgroundAudio = false;
    notifyListeners();
    await PipService.instance.stopBackgroundPlayback();
  }

  Future<void> close() async {
    if (isBackgroundAudio) {
      await PipService.instance.stopBackgroundPlayback();
    }
    await _disposeCurrent();
    notifyListeners();
  }

  Future<void> _disposeCurrent() async {
    final video = currentVideo;
    final ctrl = controller;
    if (!SettingsService.instance.isMusicMode &&
        video?.id != null && ctrl != null && ctrl.value.isInitialized) {
      final pos = ctrl.value.position;
      final dur = ctrl.value.duration;
      if (pos > _resumeThreshold && pos < dur - _resumeThreshold) {
        await _db.updateLastPosition(video!.id!, pos.inMilliseconds);
      }
    }
    cancelSleepTimer();
    await _stopAudioEngine();
    skips = [];
    pendingSkipStart = null;
    controller?.removeListener(_onTick);
    chewieController?.dispose();
    await controller?.dispose();
    controller = null;
    chewieController = null;
    _videoControllerVideoId = null;
    currentVideo = null;
    playlist = null;
    currentIndex = 0;
    isMinimized = false;
    isBackgroundAudio = false;
    activeRange = null;
    adhocLoop = false;
    adhocStart = null;
    adhocEnd = null;
    if (_wakelockOn) {
      _wakelockOn = false;
      await WakelockPlus.disable();
    }
  }

  // ── Громкость ────────────────────────────────────────────────────────

  void setVolume(double v) {
    volume = v.clamp(0.0, 1.0).toDouble();
    controller?.setVolume(volume);
    _audio?.setVolume(volume);
    notifyListeners();
  }

  // ── Фоновый звук: передача между video_player и just_audio ───────────

  void _onLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        // Запоминаем состояние ДО того, как плагин успеет остановить плеер.
        final ctrl = controller;
        if (!_audioActive && ctrl != null && ctrl.value.isInitialized) {
          _playingAtLeave = ctrl.value.isPlaying;
          _positionAtLeave = ctrl.value.position;
        }
        // Заранее открываем файл в аудиоплеере (обычно к моменту hidden/paused уже готов).
        if (isBackgroundAudio && !_audioActive && currentVideo != null) {
          _preparing = _prepareAudio(currentVideo!);
        }
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _switchToAudioEngine();
        break;
      case AppLifecycleState.resumed:
        _returnToVideo();
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Приложение свернули при включённом «звук в фоне»: звук ведёт аудиоплеер.
  Future<void> _switchToAudioEngine() async {
    if (!isBackgroundAudio || _audioActive || _audioSwitching) return;
    final video = currentVideo;
    final ctrl = controller;
    if (video == null || ctrl == null || !ctrl.value.isInitialized) return;
    final playing = _playingAtLeave || ctrl.value.isPlaying;
    var pos = ctrl.value.position;
    if (_positionAtLeave > pos) pos = _positionAtLeave;
    _audioSwitching = true;
    try {
      final audio = _audio ??= AudioPlayer();
      await _audioPosSub?.cancel();
      await _audioStateSub?.cancel();
      // Файл обычно уже открыт заранее (_prepareAudio) — тогда остаётся только
      // перемотать и включить, и «дырка» в звуке почти незаметна.
      await _preparing;
      if (_preparedAudioVideoId != video.id) {
        await audio.setFilePath(video.filePath);
        _preparedAudioVideoId = video.id;
      }
      await audio.setVolume(volume);
      await audio.seek(pos);
      _audioActive = true;
      _audioPosSub = audio.positionStream.listen(_onAudioTick);
      _audioStateSub = audio.playerStateStream.listen((_) => _onAudioTick(audio.position));
      if (playing) audio.play(); // Future завершается только по окончании — не ждём
      // Сначала глушим видео-плеер (звук уже ведёт аудиоплеер), потом ставим на паузу.
      await ctrl.setVolume(0);
      await ctrl.pause();
    } catch (_) {
      // Не вышло запустить аудио-движок — остаёмся на video_player как раньше.
      _audioActive = false;
    } finally {
      _audioSwitching = false;
    }
    notifyListeners();
  }

  void _onAudioTick(Duration pos) {
    final audio = _audio;
    if (!_audioActive || _audioSwitching || audio == null) return;
    final dur = audio.duration ?? controller?.value.duration ?? Duration.zero;
    final completed = audio.processingState == ProcessingState.completed;
    final playing = audio.playing && !completed;
    _tick(pos, dur, playing,
        seek: (d) => audio.seek(d),
        play: () async { audio.play(); });
  }

  /// Следующий ролик, пока приложение в фоне: грузим его в аудио-движок
  /// (видео-плеер без поверхности всё равно не заиграет).
  Future<void> _loadInAudioEngine(Video video, {List<Video>? playlist, int? index}) async {
    final audio = _audio;
    if (audio == null) return;
    _audioSwitching = true;
    try {
      final file = File(video.filePath);
      if (!await file.exists()) return;
      // Видео-плеер от предыдущего ролика больше не нужен.
      controller?.removeListener(_onTick);
      chewieController?.dispose();
      await controller?.dispose();
      controller = null;
      chewieController = null;
      _videoControllerVideoId = null;

      currentVideo = video;
      this.playlist = playlist;
      currentIndex = index ?? 0;
      activeRange = video.id == null ? null : await _db.getDefaultRange(video.id!);
      skips = video.id == null ? [] : await _db.getSkipsForVideo(video.id!);
      pendingSkipStart = null;
      _lastSkipAt = null;
      adhocLoop = false;
      adhocStart = null;
      adhocEnd = null;
      _endHandled = false;
      pendingResumeChoice = null;

      await audio.setFilePath(video.filePath);
      _preparedAudioVideoId = video.id;
      final dur = audio.duration ?? Duration.zero;
      final saved = SettingsService.instance.isMusicMode
          ? Duration.zero
          : Duration(milliseconds: video.lastPositionMs);
      var start = Duration.zero;
      if (activeRange != null) {
        start = activeRange!.start;
      } else if (saved > _resumeThreshold && saved < dur - _resumeThreshold) {
        start = saved;
      }
      await audio.seek(start);
      audio.play();
      notifyListeners();
      _syncPipState();
    } catch (_) {
      hasError = true;
    } finally {
      _audioSwitching = false;
    }
  }

  /// Вернулись в приложение: звук передаём обратно видео-плееру с того же места.
  Future<void> _returnToVideo() async {
    if (!_audioActive) return;
    final audio = _audio;
    final video = currentVideo;
    final pos = audio?.position ?? Duration.zero;
    final playing = (audio?.playing ?? false) &&
        audio?.processingState != ProcessingState.completed;
    final keepBackgroundAudio = isBackgroundAudio;
    await _stopAudioEngine(keepPrepared: true);
    if (video == null) return;

    final ctrl = controller;
    if (ctrl != null && _videoControllerVideoId == video.id && ctrl.value.isInitialized) {
      await ctrl.setVolume(volume); // в фоне видео-плеер был заглушен
      await ctrl.seekTo(pos);
      if (playing) {
        await ctrl.play();
      } else {
        await ctrl.pause();
      }
      notifyListeners();
      return;
    }
    // Ролик сменился, пока играл только звук — видео-плеер создаём заново.
    await loadAndPlay(video,
        playlist: playlist, index: currentIndex,
        startAt: pos, autoPlay: playing, force: true);
    isBackgroundAudio = keepBackgroundAudio;
    notifyListeners();
  }

  /// [keepPrepared] — при возврате из фона оставляем файл открытым (просто пауза),
  /// чтобы следующее сворачивание снова было без заметной «дырки». Если видео
  /// закрывают или сменили — полная остановка.
  Future<void> _stopAudioEngine({bool keepPrepared = false}) async {
    _audioActive = false;
    await _audioPosSub?.cancel();
    await _audioStateSub?.cancel();
    _audioPosSub = null;
    _audioStateSub = null;
    try {
      if (keepPrepared) {
        await _audio?.pause();
      } else {
        _preparedAudioVideoId = null;
        await _audio?.stop();
      }
    } catch (_) {}
  }

  /// Открывает файл [video] в аудиоплеере заранее (без воспроизведения).
  Future<void> _prepareAudio(Video video) async {
    if (_preparedAudioVideoId == video.id || _audioActive) return;
    try {
      final audio = _audio ??= AudioPlayer();
      _preparedAudioVideoId = null;
      await audio.setFilePath(video.filePath);
      await audio.setVolume(volume);
      _preparedAudioVideoId = video.id;
    } catch (_) {
      _preparedAudioVideoId = null;
    }
  }

  // ── Таймер сна ───────────────────────────────────────────────────────
  // Ставит на паузу (не закрывает плеер) по истечении времени — чтобы
  // случайно не потерять место просмотра/не прервать фоновый звук совсем,
  // просто перестаёт играть дальше само по себе.

  void setSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepTimerEndsAt = DateTime.now().add(duration);
    sleepTimerRemaining = duration;
    notifyListeners();
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final endsAt = _sleepTimerEndsAt;
      if (endsAt == null) return;
      final remaining = endsAt.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        controller?.pause();
        _audio?.pause();
        cancelSleepTimer();
        notifyListeners();
      } else {
        sleepTimerRemaining = remaining;
        notifyListeners();
      }
    });
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndsAt = null;
    sleepTimerRemaining = null;
  }
}

/// Передаёт события жизненного цикла приложения менеджеру (WidgetsBindingObserver
/// нельзя подмешать в ChangeNotifier-синглтон напрямую без лишних зависимостей).
class _LifecycleBridge with WidgetsBindingObserver {
  final PlaybackManager _manager;
  _LifecycleBridge(this._manager);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _manager._onLifecycle(state);
}
