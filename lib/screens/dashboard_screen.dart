import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vpn_state_provider.dart';
import '../widgets/traffic_chart.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vpnState = ref.watch(vpnStateProvider);
    final activeChain = ref.watch(activeChainProvider);

    return Scaffold(
      backgroundColor: Colors.grey[100],
      appBar: AppBar(
        title: const Text('ProxyChain Core', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            children: [
              const SizedBox(height: 20),
              // 1. 巨大的圆形操作按钮
              _buildMainButton(context, ref, vpnState),
              
              const SizedBox(height: 40),
              
              // 2. 当前选中的代理链显示
              _buildProxyChainDisplay(activeChain),
              
              const SizedBox(height: 40),
              
              // 3. 流量折线图组件
              const Expanded(
                child: TrafficChart(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMainButton(BuildContext context, WidgetRef ref, VpnConnectionState state) {
    Color buttonColor;
    IconData buttonIcon;
    String buttonText;

    switch (state) {
      case VpnConnectionState.disconnected:
        buttonColor = Colors.redAccent;
        buttonIcon = Icons.power_settings_new;
        buttonText = 'TAP TO CONNECT';
        break;
      case VpnConnectionState.connecting:
        buttonColor = Colors.orangeAccent;
        buttonIcon = Icons.autorenew;
        buttonText = 'CONNECTING...';
        break;
      case VpnConnectionState.connected:
        buttonColor = Colors.green;
        buttonIcon = Icons.vpn_lock;
        buttonText = 'CONNECTED';
        break;
    }

    return GestureDetector(
      onTap: () async {
        // 模拟状态切换逻辑
        if (state == VpnConnectionState.disconnected) {
          ref.read(vpnStateProvider.notifier).state = VpnConnectionState.connecting;
          // 模拟连接耗时
          await Future.delayed(const Duration(seconds: 2));
          ref.read(vpnStateProvider.notifier).state = VpnConnectionState.connected;
        } else if (state == VpnConnectionState.connected) {
          ref.read(vpnStateProvider.notifier).state = VpnConnectionState.disconnected;
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: buttonColor,
          boxShadow: [
            BoxShadow(
              color: buttonColor.withOpacity(0.4),
              blurRadius: 20,
              spreadRadius: 10,
            )
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(buttonIcon, size: 60, color: Colors.white),
            const SizedBox(height: 10),
            Text(
              buttonText,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProxyChainDisplay(activeChain) {
    if (activeChain == null) {
      return const Text('No proxy chain selected', style: TextStyle(color: Colors.grey));
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            spreadRadius: 1,
          )
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 入口节点
          Expanded(
            child: Column(
              children: [
                const Text('Entry Node', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Text(
                  activeChain.entryNode.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          
          // 箭头
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Icon(Icons.arrow_forward_rounded, color: Colors.deepPurple),
          ),
          
          // 出口节点
          Expanded(
            child: Column(
              children: [
                const Text('Exit Node', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Text(
                  activeChain.exitNode.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
