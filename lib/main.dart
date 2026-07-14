import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'screens/home_screen.dart';
import 'screens/albums_screen.dart';
import 'screens/download_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          const HomeScreen(),
          const AlbumsScreen(),
          DownloadScreen(
            initialUrl: _sharedUrl,
            onUrlConsumed: () => setState(() => _sharedUrl = null),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.video_library_outlined),
              selectedIcon: Icon(Icons.video_library), label: 'Videos'),
          NavigationDestination(icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder), label: 'Albums'),
          NavigationDestination(icon: Icon(Icons.download_outlined),
              selectedIcon: Icon(Icons.download), label: 'Download'),
        ],
      ),
    );
  }
}
