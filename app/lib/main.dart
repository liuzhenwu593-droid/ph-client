import 'package:flutter/material.dart';

import 'downloads.dart';
import 'local_store.dart';
import 'pages/categories_page.dart';
import 'pages/favorites_page.dart';
import 'pages/home_page.dart';
import 'pages/pin_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'ph_api.dart';
import 'play_cache.dart';
import 'settings.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  final cache = await PlaybackCache.load();
  final favorites = await FavoritesStore.load();
  final watch = await WatchStore.load();
  final searchHistory = await SearchHistoryStore.load();
  final downloads = await DownloadManager.load();
  runApp(
    PhPlayerApp(
      settings: settings,
      cache: cache,
      favorites: favorites,
      watch: watch,
      searchHistory: searchHistory,
      downloads: downloads,
    ),
  );
}

class PhPlayerApp extends StatefulWidget {
  const PhPlayerApp({
    super.key,
    required this.settings,
    required this.cache,
    required this.favorites,
    required this.watch,
    required this.searchHistory,
    required this.downloads,
  });

  final AppSettings settings;
  final PlaybackCache cache;
  final FavoritesStore favorites;
  final WatchStore watch;
  final SearchHistoryStore searchHistory;
  final DownloadManager downloads;

  @override
  State<PhPlayerApp> createState() => _PhPlayerAppState();
}

class _PhPlayerAppState extends State<PhPlayerApp> {
  late final PhApi _api = PhApi(
    backendUrl: widget.settings.backendUrl,
    cache: widget.cache,
  );
  bool _pinUnlocked = false;

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (widget.settings.pinEnabled && !_pinUnlocked) {
      home = PinScreen(
        mode: PinMode.verify,
        title: '输入 PIN 进入 PsexHub',
        hint: '忘记 PIN 只能卸载重装清除。',
        onSubmit: (pin) async {
          final ok = widget.settings.checkPin(pin);
          if (ok) setState(() => _pinUnlocked = true);
          return ok;
        },
      );
    } else if (!widget.settings.ageConfirmed) {
      home = AgeGateScreen(
        settings: widget.settings,
        api: _api,
        favorites: widget.favorites,
        watch: widget.watch,
        searchHistory: widget.searchHistory,
        downloads: widget.downloads,
      );
    } else {
      home = MainScreen(
        settings: widget.settings,
        api: _api,
        favorites: widget.favorites,
        watch: widget.watch,
        searchHistory: widget.searchHistory,
        downloads: widget.downloads,
      );
    }
    return MaterialApp(
      title: 'PsexHub',
      theme: ThemeData.dark(useMaterial3: true),
      home: home,
    );
  }
}

class AgeGateScreen extends StatelessWidget {
  const AgeGateScreen({
    super.key,
    required this.settings,
    required this.api,
    required this.favorites,
    required this.watch,
    required this.searchHistory,
    required this.downloads,
  });

  final AppSettings settings;
  final PhApi api;
  final FavoritesStore favorites;
  final WatchStore watch;
  final SearchHistoryStore searchHistory;
  final DownloadManager downloads;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.warning, size: 64),
              const SizedBox(height: 24),
              const Text(
                '仅限 18 岁以上使用',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                '本 App 包含成人内容。继续使用即表示你已年满 18 岁，'
                '且所在地区允许你访问此类内容。',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () async {
                  await settings.confirmAge();
                  if (context.mounted) {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => MainScreen(
                          settings: settings,
                          api: api,
                          favorites: favorites,
                          watch: watch,
                          searchHistory: searchHistory,
                          downloads: downloads,
                        ),
                      ),
                    );
                  }
                },
                child: const Text('我已满 18 岁，进入'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.maybePop(context),
                child: const Text('退出'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({
    super.key,
    required this.settings,
    required this.api,
    required this.favorites,
    required this.watch,
    required this.searchHistory,
    required this.downloads,
  });

  final AppSettings settings;
  final PhApi api;
  final FavoritesStore favorites;
  final WatchStore watch;
  final SearchHistoryStore searchHistory;
  final DownloadManager downloads;

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _index = 0;

  void _onBackendChanged(String url) {
    widget.api.setBackendUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(
        api: widget.api,
        favorites: widget.favorites,
        watch: widget.watch,
        settings: widget.settings,
        downloads: widget.downloads,
      ),
      CategoriesPage(
        api: widget.api,
        favorites: widget.favorites,
        watch: widget.watch,
        settings: widget.settings,
        downloads: widget.downloads,
      ),
      SearchPage(
        api: widget.api,
        favorites: widget.favorites,
        watch: widget.watch,
        settings: widget.settings,
        downloads: widget.downloads,
        searchHistory: widget.searchHistory,
      ),
      FavoritesPage(
        api: widget.api,
        favorites: widget.favorites,
        watch: widget.watch,
        settings: widget.settings,
        downloads: widget.downloads,
      ),
      SettingsPage(
        settings: widget.settings,
        api: widget.api,
        onBackendChanged: _onBackendChanged,
        favorites: widget.favorites,
        watch: widget.watch,
        downloads: widget.downloads,
      ),
    ];
    const titles = ['首页', '分类', '搜索', '收藏', '设置'];
    return Scaffold(
      appBar: AppBar(title: Text(titles[_index])),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: '首页'),
          BottomNavigationBarItem(icon: Icon(Icons.grid_view), label: '分类'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: '搜索'),
          BottomNavigationBarItem(icon: Icon(Icons.star), label: '收藏'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}
