import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_app/src/rust/frb_generated.dart';
import 'screens/dashboard_screen.dart';
import 'screens/chain_builder_screen.dart';
import 'services/config_manager.dart';
import 'providers/vpn_state_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ConfigManager.init(); // 初始化本地配置
  await RustLib.init();
  
  final container = ProviderContainer();
  setupConfigListeners(container);
  
  // 使用 UncontrolledProviderScope 包装 MyApp 以启用 Riverpod 且支持全局监听
  runApp(UncontrolledProviderScope(
    container: container,
    child: const MyApp(),
  ));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ProxyChain Core',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
        fontFamily: 'Segoe UI', // 为了更好的跨平台字体展示
      ),
      home: const MainLayout(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// 主层级布局，管理底部导航栏
class MainLayout extends StatefulWidget {
  const MainLayout({super.key});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  int _currentIndex = 0;
  
  // 管理底部的两个屏幕
  final _screens = const [
    DashboardScreen(),
    ChainBuilderScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        selectedItemColor: Colors.deepPurple,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard),
            label: '总览',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.link),
            label: '代理链构建',
          ),
        ],
      ),
    );
  }
}
