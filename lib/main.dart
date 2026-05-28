import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _loadGreeting();
  }

  void _loadGreeting() {
    // 调用 Rust 的 greet 函数
    final result = greet(name: 'Flutter Developer');
    setState(() {
      _greeting = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter + Rust (FRB V2)'),
      ),
      body: Center(
        child: Text(
          _greeting,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
