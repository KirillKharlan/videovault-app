import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'screens/home_screen.dart';
import 'models/database.dart';
import 'screens/albums_screen.dart';
import 'screens/download_screen.dart';
import 'screens/download_queue_screen.dart';
import 'screens/settings_screen.dart';
import 'services/download_manager.dart';
import 'services/local_ytdlp_service.dart';
import 'services/settings_service.dart';
import 'services/update_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  await SettingsService.instance.load();
  runApp(const VideoVaultApp());
}

class VideoVaultApp extends StatelessWidget {
  const VideoVaultApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VideoVault',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const MainScreen(),
    );
  }

  ThemeData _buildTheme() {
    const purple = Color(0xFF7C5CFC);
    const bg = Color(0xFF0D0D12);
    const surface = Color(0xFF16161E);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: purple,
        surface: surface,
        background: bg,
        onPrimary: Colors.white,
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: bg,
      cardColor: surface,
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: purple.withOpacity(0.2),
        iconTheme: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.selected)) {
            return const IconThemeData(color: purple);
          }
          return const IconThemeData(color: Color(0xFF555577));
        }),
        labelTextStyle: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.selected)) {
            return const TextStyle(color: purple, fontSize: 12);
          }
          return const TextStyle(color: Color(0xFF555577), fontSize: 12);
        }),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: purple,
        foregroundColor: Colors.white,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF2A2A38)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF2A2A38)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: purple, width: 2),
        ),
        hintStyle: const TextStyle(color: Color(0xFF55556A)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: purple,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          minimumSize: const Size(double.infinity, 52),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

// ─── Main Navigation ─────────────────────────────────────────────────────────

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _index = 0;
  String? _sharedUrl;

  /// Открытый альбом: пока он не null, между Albums и Download есть вкладка с
  /// его названием. Вкладка живёт, пока её не закроют крестиком: можно уйти на
  /// другие вкладки и вернуться — список, прокрутка и выбор сохраняются.
  Album? _openAlbum;

  @override
  void initState() {
    super.initState();
    _listenForSharedUrls();
    _checkForUpdateOnStart();
    _updateYtDlpInBackground();
    DBChangeNotifier.instance.addListener(_refreshOpenAlbum);
  }

  @override
  void dispose() {
    DBChangeNotifier.instance.removeListener(_refreshOpenAlbum);
    super.dispose();
  }

  void _openAlbumTab(Album album) {
    setState(() { _openAlbum = album; _index = _albumPage; });
  }

  void _closeAlbumTab() {
    setState(() { _openAlbum = null; _index = 1; });
  }

  /// Альбом переименовали или удалили, пока его вкладка открыта: обновляем
  /// название в меню либо закрываем вкладку.
  Future<void> _refreshOpenAlbum() async {
    final open = _openAlbum;
    if (open == null || open.id == null) return;
    final albums = await AppDatabase().getAlbums();
    if (!mounted || _openAlbum?.id != open.id) return;
    final match = albums.where((a) => a.id == open.id);
    if (match.isEmpty) {
      setState(() {
        _openAlbum = null;
        if (_index == _albumPage) _index = 1;
      });
    } else if (match.first.name != open.name) {
      setState(() => _openAlbum = match.first);
    }
  }

  /// Название для нижнего меню: коротко, чтобы шесть вкладок помещались.
  static String _shortName(String name) =>
      name.length <= 9 ? name : '${name.substring(0, 8)}…';

  /// Если включено скачивание на телефоне — раз в 12 часов тихо обновляем
  /// встроенный yt-dlp (иначе YouTube быстро перестаёт работать).
  Future<void> _updateYtDlpInBackground() async {
    if (SettingsService.instance.downloadMode == DownloadMode.server) return;
    await Future.delayed(const Duration(seconds: 8));
    await LocalYtdlpService.instance.autoUpdateIfDue();
  }

  /// Один раз за запуск тихо смотрим, нет ли новой сборки; если есть —
  /// предлагаем открыть Настройки (там скачивание и установка).
  Future<void> _checkForUpdateOnStart() async {
    if (!UpdateService.enabled) return;
    await Future.delayed(const Duration(seconds: 3));
    final updates = UpdateService.instance;
    await updates.check();
    final info = updates.available;
    if (!mounted || info == null || updates.status != UpdateStatus.available) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Доступна новая сборка #${info.build}'),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: 'Обновить',
        onPressed: () {
          if (mounted) setState(() => _index = 4);
        },
      ),
    ));
  }

  // Принимаем ссылки из YouTube/TikTok/Instagram через "Поделиться"
  void _listenForSharedUrls() {
    ReceiveSharingIntent.instance.getMediaStream().listen((values) {
      final url = values.firstOrNull?.path;
      if (url != null && url.startsWith('http')) {
        setState(() { _sharedUrl = url; _index = 2; });
      }
    });

    ReceiveSharingIntent.instance.getInitialMedia().then((values) {
      final url = values.firstOrNull?.path;
      if (url != null && url.startsWith('http')) {
        setState(() { _sharedUrl = url; _index = 2; });
      }
    });
  }

  // Страницы IndexedStack фиксированы: 0 Videos, 1 Albums, 2 Download,
  // 3 Queue, 4 Settings, 5 Album (открытый альбом). В нижнем меню порядок
  // другой: Videos, Albums, [Album], Download, [Queue], Settings — вкладки
  // Album и Queue видны не всегда, поэтому соответствие меню ↔ страницы
  // строится списком `order` в build().
  static const _queuePage = 3;
  static const _albumPage = 5;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DownloadManager.instance,
      builder: (context, _) {
        final mgr = DownloadManager.instance;
        final queueVisible = mgr.showQueueTab;

        final albumVisible = _openAlbum != null;

        // Вкладка очереди пропала, пока мы на ней — переходим на Download.
        if (!queueVisible && _index == _queuePage) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _index == _queuePage) setState(() => _index = 2);
          });
        }
        var page = _index;
        if (!queueVisible && page == _queuePage) page = 2;
        if (!albumVisible && page == _albumPage) page = 1;

        // Страницы в порядке нижнего меню.
        final order = <int>[0, 1, if (albumVisible) _albumPage, 2, if (queueVisible) _queuePage, 4];
        int toDisplay(int real) => order.indexOf(real).clamp(0, order.length - 1).toInt();
        int toReal(int display) => order[display.clamp(0, order.length - 1).toInt()];

        return Scaffold(
          body: Column(
            children: [
              Expanded(
                child: IndexedStack(
                  index: page,
                  children: [
                    const HomeScreen(),
                    AlbumsScreen(onOpenAlbum: _openAlbumTab),
                    DownloadScreen(
                      initialUrl: _sharedUrl,
                      onUrlConsumed: () => setState(() => _sharedUrl = null),
                    ),
                    const DownloadQueueScreen(),
                    const SettingsScreen(),
                    // Страница 5: открытый альбом. Ключ по id — при открытии
                    // другого альбома состояние создаётся заново.
                    _openAlbum == null
                        ? const SizedBox.shrink()
                        : AlbumDetailScreen(
                            key: ValueKey('album-${_openAlbum!.id}'),
                            album: _openAlbum!,
                            onClose: _closeAlbumTab,
                            isActive: page == _albumPage,
                          ),
                  ],
                ),
              ),
              // Видна с любой вкладки, пока идёт скачивание — не нужно
              // возвращаться на вкладку "Download", чтобы понять, жива ли
              // загрузка ещё. Тап ведёт в очередь (если она есть), иначе на
              // вкладку загрузки.
              if (mgr.isDownloading)
                InkWell(
                  onTap: () => setState(() => _index = queueVisible ? _queuePage : 2),
                  child: Container(
                    color: const Color(0xFF16161E),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(children: [
                      SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, value: mgr.progress > 0 ? mgr.progress : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(mgr.title ?? 'Загрузка…',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 13)),
                          Text(
                            mgr.pendingCount > 1
                                ? '${mgr.statusText} · в очереди ещё ${mgr.pendingCount - 1}'
                                : mgr.statusText,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                        ]),
                      ),
                      Text('${(mgr.progress * 100).toInt()}%',
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ]),
                  ),
                ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: toDisplay(page),
            onDestinationSelected: (d) => setState(() => _index = toReal(d)),
            // Шесть вкладок (альбом + очередь): подписи только у выбранной.
            labelBehavior: order.length > 5
                ? NavigationDestinationLabelBehavior.onlyShowSelected
                : NavigationDestinationLabelBehavior.alwaysShow,
            destinations: [
              const NavigationDestination(icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library), label: 'Videos'),
              const NavigationDestination(icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder), label: 'Albums'),
              if (albumVisible)
                NavigationDestination(
                  icon: const Icon(Icons.folder_open_outlined),
                  selectedIcon: const Icon(Icons.folder_open),
                  label: _shortName(_openAlbum!.name),
                  tooltip: _openAlbum!.name,
                ),
              const NavigationDestination(icon: Icon(Icons.download_outlined),
                  selectedIcon: Icon(Icons.download), label: 'Download'),
              if (queueVisible)
                NavigationDestination(
                  icon: Badge(
                    label: Text('${mgr.pendingCount}'),
                    isLabelVisible: mgr.pendingCount > 0,
                    child: const Icon(Icons.format_list_numbered),
                  ),
                  label: 'Queue',
                ),
              const NavigationDestination(icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings), label: 'Settings'),
            ],
          ),
        );
      },
    );
  }
}
