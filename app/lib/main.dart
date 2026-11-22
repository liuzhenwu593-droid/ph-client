import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'pages/search_page.dart';
import 'pages/settings_page.dart';
import 'ph_api.dart';
import 'settings.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(PhPlayerApp(settings: settings));
}

class PhPlayerApp extends StatefulWidget {
  const PhPlayerApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<PhPlayerApp> createState() => _PhPlayerAppState();
}

class _PhPlayerAppState extends State<PhPlayerApp> {
  late final PhApi _api = PhApi(backendUrl: widget.settings.backendUrl);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PH Player',
      theme: ThemeData.dark(useMaterial3: true),
      home: widget.settings.ageConfirmed
          ? MainScreen(settings: widget.settings, api: _api)
          : AgeGateScreen(
              settings: widget.settings,
              api: _api,
            ),
    );
  }
}

class AgeGateScreen extends StatelessWidget {
  const AgeGateScreen({super.key, required this.settings, required this.api});

  final AppSettings settings;
  final PhApi api;

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
                        builder: (_) =>
                            MainScreen(settings: settings, api: api),
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
  const MainScreen({super.key, required this.settings, required this.api});

  final AppSettings settings;
  final PhApi api;

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
      HomePage(api: widget.api),
      SearchPage(api: widget.api),
      SettingsPage(
        settings: widget.settings,
        api: widget.api,
        onBackendChanged: _onBackendChanged,
      ),
    ];
    const titles = ['首页', '搜索', '设置'];
    return Scaffold(
      appBar: AppBar(title: Text(titles[_index])),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: '首页'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: '搜索'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}
