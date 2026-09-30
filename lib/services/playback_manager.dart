import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/database.dart';
import 'pip_service.dart';

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

  // ── Продолжить с места остановки ────────────────────────────────────
  // Порог, ниже/выше которого не считаем нужным ни сохранять, ни
  // предлагать резюме — самое начало или практически конец видео.
  static const _resumeThreshold = Duration(seconds: 5);
  DateTime? _lastPositionSaveTime;
  /// Не null только когда у видео есть И диапазон, И позиция остановки —
  /// PlayerScreen должен спросить пользователя и, если выбрана позиция,
  /// заново перемотать (по умолчанию уже применён диапазон при загрузке).
  ResumeChoice? pendingResumeChoice;

  // ── Таймер сна ───────────────────────────────────────────────────────
  Duration? sleepTimerRemaining;
  Timer? _sleepTimer;
  DateTime? _sleepTimerEndsAt;

  bool get hasNext => playlist != null && currentIndex < playlist!.length - 1;
  bool get isPlaying => controller?.value.isPlaying ?? false;

  bool get isLoopActive => activeRange != null || adhocLoop;
  Duration get effectiveStart =>
      activeRange?.start ?? adhocStart ?? Duration.zero;
  Duration get effectiveEnd =>
      activeRange?.end ?? adhocEnd ?? (controller?.value.duration ?? Duration.zero);
  String get endBehavior => activeRange?.endBehavior ?? 'loop';

  Future<void> loadAndPlay(Video video, {List<Video>? playlist, int? index}) async {
    if (currentVideo?.id == video.id && controller != null && !hasError) {
      isMinimized = false;
      notifyListeners();
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
    controller!.addListener(_onTick);

    activeRange = await _db.getDefaultRange(video.id!);
    adhocLoop = false;
    adhocStart = null;
    adhocEnd = null;
    _endHandled = false;
    pendingResumeChoice = null;

    final saved = Duration(milliseconds: video.lastPositionMs);
    final dur = controller!.value.duration;
    final hasSavedPosition = saved > _resumeThreshold && saved < dur - _resumeThreshold;

    if (activeRange != null && hasSavedPosition) {
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
      autoPlay: true,
      looping: false,
      allowFullScreen: true,
      allowMuting: true,
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
    if (ctrl == null || !ctrl.value.isInitialized) return;
    final pos = ctrl.value.position;
    final dur = ctrl.value.duration;

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
          ctrl.seekTo(effectiveStart);
          if (!ctrl.value.isPlaying) ctrl.play();
        }
      }
      return;
    }

    if (!_endHandled && dur > Duration.zero &&
        pos >= dur - const Duration(milliseconds: 300) &&
        !ctrl.value.isPlaying) {
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

  /// Сохраняет позицию не чаще раза в 5 секунд — на каждый тик было бы
  /// слишком часто для записи на диск. Не сохраняем совсем в начале/конце
  /// ролика — нет смысла запоминать "продолжить с 0:02" или с последней секунды.
  void _maybeSavePosition(Duration pos, Duration dur) {
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
      await PipService.instance.updateBackgroundNotification(
          title: first.title, isPlaying: true);
    }
    if (wasMinimized) {
      isMinimized = true;
      notifyListeners();
    }
  }

  void togglePlayPause() {
    if (controller == null) return;
    if (controller!.value.isPlaying) {
      controller!.pause();
      final video = currentVideo;
      final pos = controller!.value.position;
      if (video?.id != null) _db.updateLastPosition(video!.id!, pos.inMilliseconds);
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
    if (video?.id != null && ctrl != null && ctrl.value.isInitialized) {
      final pos = ctrl.value.position;
      final dur = ctrl.value.duration;
      if (pos > _resumeThreshold && pos < dur - _resumeThreshold) {
        await _db.updateLastPosition(video!.id!, pos.inMilliseconds);
      }
    }
    cancelSleepTimer();
    controller?.removeListener(_onTick);
    chewieController?.dispose();
    await controller?.dispose();
    controller = null;
    chewieController = null;
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
