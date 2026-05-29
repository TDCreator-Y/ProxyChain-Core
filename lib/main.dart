import 'package:flutter/material.dart';
import 'package:flutter_rust_app/src/rust/api/proxy.dart';
import 'package:flutter_rust_app/src/rust/api/simple.dart';
import 'package:flutter_rust_app/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Rust App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String _greeting = 'Loading...';
  ProxyChain? _mockChain;

  @override
  void initState() {
    super.initState();
    _loadGreeting();
    _loadMockChain();
  }

  void _loadGreeting() {
    // 调用 Rust 的 greet 函数
    final result = greet(name: 'Flutter Developer');
    setState(() {
      _greeting = result;
    });
  }

  void _loadMockChain() {
    // 调用 Rust 生成的 Mock 代理链
    final result = createMockChain();
    setState(() {
      _mockChain = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ProxyChain-Core'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _greeting,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 30),
            if (_mockChain != null) ...[
              const Text(
                'Mock Proxy Chain Loaded:',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              _buildNodeCard("Entry Node", _mockChain!.entryNode),
              const Icon(Icons.arrow_downward, size: 30, color: Colors.grey),
              _buildNodeCard("Exit Node", _mockChain!.exitNode),
            ] else
              const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeCard(String title, ProxyNode node) {
    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.all(15.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple)),
            const Divider(),
            Text('ID: ${node.id}'),
            Text('Name: ${node.name}'),
            Text('Protocol: ${node.protocol.name}'),
            Text('Server: ${node.server}:${node.port}'),
            if (node.cipher != null) Text('Cipher: ${node.cipher}'),
          ],
        ),
      ),
    );
  }
}
