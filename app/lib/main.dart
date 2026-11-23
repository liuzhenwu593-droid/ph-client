import 'package:flutter/material.dart';

import 'downloads.dart';
import 'local_store.dart';
import 'pages/calculator_page.dart';
import 'pages/categories_page.dart';
import 'pages/favorites_page.dart';
import 'pages/history_page.dart';
import 'pages/home_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'ph_api.dart';
import 'play_cache.dart';
import 'settings.dart';
import 'widgets/grid_toggle.dart';

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
  // Calculator disguise (v0.2.6): cold start always shows the calculator.
  // The unlocked state lives only in memory — it is never persisted, so
  // reopening the app always shows the calculator again. The calculator
  // replaces the old 18+ gate; there is no separate age prompt anymore.
  bool _unlocked = false;

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (!_unlocked) {
      home = CalculatorPage(onUnlock: () => setState(() => _unlocked = true));
    } else {
      home = MainScreen(
        settings: widget.settings,
        api: _api,
        favorites: widget.favorites,
        watch: widget.watch,
        searchHistory: widget.searchHistory,
        downloads: widget.downloads,
        onLock: () => setState(() => _unlocked = false),
      );
    }
    return MaterialApp(
      title: '计算器',
      theme: ThemeData.dark(useMaterial3: true),
      home: home,
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
    required this.onLock,
  });

  final AppSettings settings;
  final PhApi api;
  final FavoritesStore favorites;
  final WatchStore watch;
  final SearchHistoryStore searchHistory;
  final DownloadManager downloads;
  /// Back to the calculator (called by the system back button on Home).
  final VoidCallback onLock;

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
    const titles = ['首页', '分类', '搜索', '收藏', '历史', '设置'];
    // Rebuilds when the layout toggle changes the column count.
    //
    // The pages list MUST be built inside this builder, not in the
    // outer build() scope. If the same widget instances are passed on
    // every rebuild, Element.updateChild reuses them as-is and the page
    // States never rebuild — v0.2.2 bug: the toggle icon changed but
    // the list layout stayed put. Fresh instances here force the pages
    // to rebuild and re-read settings.gridColumns. Page State is
    // preserved (same type at the same IndexedStack slot), so scroll
    // position and loaded lists survive the toggle.
    return ListenableBuilder(
      listenable: widget.settings,
      builder: (context, _) {
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
      HistoryPage(
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
    // System back on the Home tab locks back to the calculator; on other
    // tabs it first goes back to Home (standard bottom-nav behavior).
    // Pushed pages (player, category videos) pop normally above this.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_index != 0) {
          setState(() => _index = 0);
        } else {
          widget.onLock();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(titles[_index]),
          // Layout toggle on video lists only: not on the category-name
          // grid (index 1, which never changes) or Settings (index 5).
          actions: _index == 1 || _index == 5
              ? null
              : [GridColumnsButton(settings: widget.settings)],
        ),
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
            BottomNavigationBarItem(icon: Icon(Icons.history), label: '历史'),
            BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设置'),
          ],
        ),
      ),
    );
      },
    );
  }
}
