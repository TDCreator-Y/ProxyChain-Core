import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_app/src/rust/api/proxy.dart';
import '../services/config_manager.dart';

// VPN 状态枚举
enum VpnConnectionState { disconnected, connecting, connected }

// 1. 全局 VPN 连接状态
final vpnStateProvider = StateProvider<VpnConnectionState>((ref) => VpnConnectionState.disconnected);

// --- 订阅链接状态 ---
final subscriptionUrlProvider = StateProvider<String>((ref) {
  return ConfigManager.getSubscriptionUrl();
});

// --- 阶段四 4.2 新增：Mock 节点池 ---
final entryPoolProvider = Provider<List<ProxyNode>>((ref) {
  return [
    const ProxyNode(id: 'entry_1', name: 'Hong Kong 01', protocol: ProxyProtocol.socks5, server: 'hk1.example.com', port: 1080, password: 'pwd', cipher: null),
    const ProxyNode(id: 'entry_2', name: 'Japan 01', protocol: ProxyProtocol.shadowsocks, server: 'jp1.example.com', port: 8388, password: 'pwd', cipher: 'aes-256-gcm'),
    const ProxyNode(id: 'entry_3', name: 'Singapore 01', protocol: ProxyProtocol.trojan, server: 'sg1.example.com', port: 443, password: 'pwd', cipher: null),
  ];
});

final exitPoolProvider = StateProvider<List<ProxyNode>>((ref) {
  final saved = ConfigManager.getExitNodesList();
  if (saved.isNotEmpty) return saved;
  return [
    const ProxyNode(id: 'exit_1', name: 'US ISP 01', protocol: ProxyProtocol.socks5, server: 'us1.example.com', port: 1080, password: 'pwd', cipher: null),
    const ProxyNode(id: 'exit_2', name: 'UK ISP 01', protocol: ProxyProtocol.shadowsocks, server: 'uk1.example.com', port: 8388, password: 'pwd', cipher: 'aes-256-gcm'),
    const ProxyNode(id: 'exit_3', name: 'TW ISP 01', protocol: ProxyProtocol.vmess, server: 'tw1.example.com', port: 443, password: 'pwd', cipher: null),
  ];
});

// --- 阶段四 4.2 新增：选中的节点状态 ---
final selectedEntryNodeProvider = StateProvider<ProxyNode?>((ref) {
  final saved = ConfigManager.getEntryNode();
  if (saved != null) return saved;
  return ref.read(entryPoolProvider).first;
});

final selectedExitNodeProvider = StateProvider<ProxyNode?>((ref) {
  final saved = ConfigManager.getExitNode();
  if (saved != null) return saved;
  return ref.read(exitPoolProvider).first;
});

// 监听状态变化并保存到本地
void setupConfigListeners(ProviderContainer container) {
  container.listen(selectedEntryNodeProvider, (previous, next) {
    if (next != null) ConfigManager.saveEntryNode(next);
  });
  
  container.listen(selectedExitNodeProvider, (previous, next) {
    if (next != null) ConfigManager.saveExitNode(next);
  });
  
  container.listen(exitPoolProvider, (previous, next) {
    ConfigManager.saveExitNodesList(next);
  });
  
  container.listen(subscriptionUrlProvider, (previous, next) {
    ConfigManager.saveSubscriptionUrl(next);
  });
}

// 2. 当前选中的代理链（基于选中的节点动态生成）
final activeChainProvider = Provider<ProxyChain?>((ref) {
  final entry = ref.watch(selectedEntryNodeProvider);
  final exit = ref.watch(selectedExitNodeProvider);
  
  if (entry != null && exit != null) {
    return ProxyChain(entryNode: entry, exitNode: exit);
  }
  return null;
});

// 流量数据模型
class TrafficData {
  final double upSpeed; // KB/s
  final double downSpeed; // KB/s
  final DateTime time;

  TrafficData(this.upSpeed, this.downSpeed, this.time);
}

// 3. 流量数据流（接入 Rust 底层真实数据）
final trafficStreamProvider = StreamProvider<TrafficData>((ref) async* {
  final state = ref.watch(vpnStateProvider);
  
  if (state == VpnConnectionState.connected) {
    final entry = ref.read(selectedEntryNodeProvider);
    final exit = ref.read(selectedExitNodeProvider);
    
    if (entry != null && exit != null) {
      try {
        // 调用 Rust 端真实接口，FRB 会将 StreamSink 自动转换为 Dart 的 Stream
        final stream = startEngine(entryNode: entry, exitNode: exit);
        
        await for (final status in stream) {
          // status.up 和 down 是 BigInt（对应 Rust 的 u64）
          // 需要先转换为 int，再除以 1024 转换为 double 的 KB/s
          yield TrafficData(
            status.up.toInt() / 1024.0,
            status.down.toInt() / 1024.0,
            DateTime.now()
          );
        }
      } catch (e) {
        print("Engine error: $e");
        ref.read(vpnStateProvider.notifier).state = VpnConnectionState.disconnected;
        yield TrafficData(0, 0, DateTime.now());
      }
    }
  } else {
    // 未连接或断开时，调用 Rust 的 stop_engine 并归零网速
    stopEngine();
    yield TrafficData(0, 0, DateTime.now());
  }
});
