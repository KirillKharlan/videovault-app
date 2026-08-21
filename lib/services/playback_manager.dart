import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
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

    if (activeRange != null) {
      await controller!.seekTo(activeRange!.start);
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
      if (hasNext) playNext();
    }

    _syncPipState();
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

  void togglePlayPause() {
    if (controller == null) return;
    if (controller!.value.isPlaying) {
      controller!.pause();
    } else {
      controller!.play();
    }
    notifyListeners();
    _syncPipState();
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
    PipService.instance.updateState(isPlaying: isPlaying, hasNext: hasNext, title: title);
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
  // Запускает foreground-сервис с уведомлением — только он не даёт Android
  // "заморозить" процесс приложения после сворачивания. Работает даже если
  // пользователь полностью свернул приложение или открыл другое.

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
  }
}
