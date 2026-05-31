import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_app/src/rust/api/proxy.dart';
import '../providers/vpn_state_provider.dart';

class ChainBuilderScreen extends ConsumerWidget {
  const ChainBuilderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entryPool = ref.watch(entryPoolProvider);
    final exitPool = ref.watch(exitPoolProvider);

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('代理链构建', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            // 区域一：Entry Pool
            Expanded(
              child: _buildPoolColumn(
                context, 
                ref, 
                title: '入口节点 (VPN)', 
                nodes: entryPool, 
                isEntry: true
              ),
            ),
            const SizedBox(width: 16),
            // 区域二：Exit Pool
            Expanded(
              child: _buildPoolColumn(
                context, 
                ref, 
                title: '出口节点 (ISP)', 
                nodes: exitPool, 
                isEntry: false
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPoolColumn(BuildContext context, WidgetRef ref, {required String title, required List<ProxyNode> nodes, required bool isEntry}) {
    final selectedNode = isEntry ? ref.watch(selectedEntryNodeProvider) : ref.watch(selectedExitNodeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
          child: Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.deepPurple),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: nodes.length,
            itemBuilder: (context, index) {
              final node = nodes[index];
              final isSelected = selectedNode?.id == node.id;
              return _buildNodeCard(context, ref, node: node, isSelected: isSelected, isEntry: isEntry);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildNodeCard(BuildContext context, WidgetRef ref, {required ProxyNode node, required bool isSelected, required bool isEntry}) {
    return GestureDetector(
      onTap: () {
        // 点击卡片更新 Riverpod 状态
        if (isEntry) {
          ref.read(selectedEntryNodeProvider.notifier).state = node;
        } else {
          ref.read(selectedExitNodeProvider.notifier).state = node;
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(vertical: 6.0),
        decoration: BoxDecoration(
          color: isSelected ? Colors.deepPurple.withOpacity(0.1) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.deepPurple : Colors.transparent,
            width: 2,
          ),
          boxShadow: [
            if (!isSelected)
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 5,
                spreadRadius: 1,
              )
          ],
        ),
        child: ListTile(
          // 根据节点名称自动匹配国旗
          leading: Text(
            _getFlag(node.name),
            style: const TextStyle(fontSize: 24),
          ),
          title: Text(
            node.name,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? Colors.deepPurple : Colors.black87,
            ),
          ),
          subtitle: Text(
            node.protocol.name.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              color: isSelected ? Colors.deepPurple.withOpacity(0.7) : Colors.grey,
            ),
          ),
          // 选中状态显示对勾
          trailing: isSelected ? const Icon(Icons.check_circle, color: Colors.deepPurple) : null,
        ),
      ),
    );
  }

  // 简单的辅助函数，用来模拟国旗展示
  String _getFlag(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('hk') || lower.contains('hong kong') || lower.contains('香港')) return '🇭🇰';
    if (lower.contains('jp') || lower.contains('japan') || lower.contains('日本')) return '🇯🇵';
    if (lower.contains('sg') || lower.contains('singapore') || lower.contains('新加坡')) return '🇸🇬';
    if (lower.contains('us') || lower.contains('united states') || lower.contains('美国')) return '🇺🇸';
    if (lower.contains('uk') || lower.contains('united kingdom') || lower.contains('英国')) return '🇬🇧';
    if (lower.contains('tw') || lower.contains('taiwan') || lower.contains('台湾')) return '🇹🇼';
    return '🌐';
  }
}
