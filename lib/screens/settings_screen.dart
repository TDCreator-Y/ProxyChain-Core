import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_app/src/rust/api/subscription.dart';
import 'package:flutter_rust_app/src/rust/api/proxy.dart';
import '../providers/vpn_state_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlController = TextEditingController();
  bool _isLoading = false;

  // ISP Form Controllers
  final _ispNameController = TextEditingController();
  final _ispServerController = TextEditingController();
  final _ispPortController = TextEditingController();
  final _ispPasswordController = TextEditingController();
  
  ProxyProtocol _ispProtocol = ProxyProtocol.socks5;
  String _ispCipher = 'aes-256-gcm';

  @override
  void initState() {
    super.initState();
    // 从全局状态恢复已保存的订阅链接
    _urlController.text = ref.read(subscriptionUrlProvider);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _ispNameController.dispose();
    _ispServerController.dispose();
    _ispPortController.dispose();
    _ispPasswordController.dispose();
    super.dispose();
  }

  void _addExitNode() {
    final name = _ispNameController.text.trim();
    final server = _ispServerController.text.trim();
    final portStr = _ispPortController.text.trim();
    final password = _ispPasswordController.text;

    if (name.isEmpty || server.isEmpty || portStr.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写完整的节点信息'), backgroundColor: Colors.redAccent),
      );
      return;
    }

    final port = int.tryParse(portStr);
    if (port == null || port <= 0 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('端口号无效'), backgroundColor: Colors.redAccent),
      );
      return;
    }

    final newNode = ProxyNode(
      id: 'exit_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      protocol: _ispProtocol,
      server: server,
      port: port,
      password: password,
      cipher: _ispProtocol == ProxyProtocol.shadowsocks ? _ispCipher : null,
    );

    ref.read(exitPoolProvider.notifier).update((state) => [...state, newNode]);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已成功添加出口节点'), backgroundColor: Colors.green),
    );

    // 清空表单
    _ispNameController.clear();
    _ispServerController.clear();
    _ispPortController.clear();
    _ispPasswordController.clear();
  }

  Future<void> _updateSubscription() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请输入有效的订阅链接 URL'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    // 保存链接到 Provider (自动触发 ConfigManager 持久化)
    ref.read(subscriptionUrlProvider.notifier).state = url;

    setState(() {
      _isLoading = true;
    });

    try {
      // 调用底层 Rust 解析引擎
      final nodes = await fetchSubscription(url: url);

      // 更新全局节点池
      ref.read(entryPoolProvider.notifier).state = nodes;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功加载 ${nodes.length} 个节点'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('更新失败: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('设置 / 订阅', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '节点订阅',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.deepPurple),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                labelText: '订阅链接 URL',
                hintText: 'https://...',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                prefixIcon: const Icon(Icons.link, color: Colors.deepPurple),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _updateSubscription,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        '更新订阅',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
              ),
            ),
            const SizedBox(height: 40),
            const Text(
              '当前状态',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.deepPurple),
            ),
            const SizedBox(height: 16),
            Consumer(
              builder: (context, ref, child) {
                final entryPool = ref.watch(entryPoolProvider);
                final exitPool = ref.watch(exitPoolProvider);
                return Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('入口节点总数', style: TextStyle(fontSize: 16)),
                          Text(
                            '${entryPool.length}',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green),
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('固定出口节点总数', style: TextStyle(fontSize: 16)),
                          Text(
                            '${exitPool.length}',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.deepPurple),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 40),
            const Text(
              '手动添加固定出口节点 (ISP)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.deepPurple),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _ispNameController,
                    decoration: const InputDecoration(labelText: '节点名称', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _ispServerController,
                          decoration: const InputDecoration(labelText: '服务器 IP', border: OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: _ispPortController,
                          decoration: const InputDecoration(labelText: '端口', border: OutlineInputBorder()),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ProxyProtocol>(
                    value: _ispProtocol,
                    decoration: const InputDecoration(labelText: '协议类型', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: ProxyProtocol.socks5, child: Text('Socks5')),
                      DropdownMenuItem(value: ProxyProtocol.shadowsocks, child: Text('Shadowsocks')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _ispProtocol = val;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _ispPasswordController,
                    decoration: const InputDecoration(labelText: '密码 (可选)', border: OutlineInputBorder()),
                    obscureText: true,
                  ),
                  if (_ispProtocol == ProxyProtocol.shadowsocks) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _ispCipher,
                      decoration: const InputDecoration(labelText: '加密方式', border: OutlineInputBorder()),
                      items: const [
                        DropdownMenuItem(value: 'aes-256-gcm', child: Text('aes-256-gcm')),
                        DropdownMenuItem(value: 'chacha20-ietf-poly1305', child: Text('chacha20-ietf-poly1305')),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _ispCipher = val;
                          });
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _addExitNode,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurple,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '保存',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
