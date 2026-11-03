import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'screens/home_screen.dart';
import 'screens/albums_screen.dart';
import 'screens/download_screen.dart';
import 'screens/download_queue_screen.dart';
import 'screens/settings_screen.dart';
import 'services/download_manager.dart';
import 'services/settings_service.dart';

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

  @override
  void initState() {
    super.initState();
    _listenForSharedUrls();
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
  // 3 Queue, 4 Settings. Вкладка "Queue" в нижнем меню видна, только когда
  // в очереди 2+ загрузок (DownloadManager.showQueueTab) — тогда индексы
  // меню и страниц совпадают, иначе всё после Download сдвигается на единицу.
  static const _queuePage = 3;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DownloadManager.instance,
      builder: (context, _) {
        final mgr = DownloadManager.instance;
        final queueVisible = mgr.showQueueTab;

        // Вкладка очереди пропала, пока мы на ней — переходим на Download.
        if (!queueVisible && _index == _queuePage) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _index == _queuePage) setState(() => _index = 2);
          });
        }
        final page = (!queueVisible && _index == _queuePage) ? 2 : _index;
        int toDisplay(int real) => queueVisible ? real : (real > _queuePage ? real - 1 : real);
        int toReal(int display) => queueVisible ? display : (display >= _queuePage ? display + 1 : display);

        return Scaffold(
          body: Column(
            children: [
              Expanded(
                child: IndexedStack(
                  index: page,
                  children: [
                    const HomeScreen(),
                    const AlbumsScreen(),
                    DownloadScreen(
                      initialUrl: _sharedUrl,
                      onUrlConsumed: () => setState(() => _sharedUrl = null),
                    ),
                    const DownloadQueueScreen(),
                    const SettingsScreen(),
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
            destinations: [
              const NavigationDestination(icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library), label: 'Videos'),
              const NavigationDestination(icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder), label: 'Albums'),
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
