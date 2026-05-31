import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_app/src/rust/api/proxy.dart';
import '../services/config_manager.dart';

// VPN 状态枚举
enum VpnConnectionState { disconnected, connecting, connected }

class VpnController extends StateNotifier<VpnConnectionState> {
  VpnController(this.ref) : super(VpnConnectionState.disconnected);

  final Ref ref;

  Future<void> connect() async {
    final entryNode = ref.read(selectedEntryNodeProvider);
    final exitNode = ref.read(selectedExitNodeProvider);

    if (entryNode == null || exitNode == null) {
      throw Exception('请先选择入口节点和固定出口节点');
    }

    state = VpnConnectionState.connecting;

    try {
      final trafficStream = startEngine(entryNode: entryNode, exitNode: exitNode);
      ref.read(engineTrafficSourceProvider.notifier).state = trafficStream;
      state = VpnConnectionState.connected;
    } catch (error) {
      ref.read(engineTrafficSourceProvider.notifier).state = null;
      state = VpnConnectionState.disconnected;
      throw Exception('连接失败: $error');
    }
  }

  Future<void> disconnect() async {
    try {
      stopEngine();
    } finally {
      ref.read(engineTrafficSourceProvider.notifier).state = null;
      state = VpnConnectionState.disconnected;
    }
  }
}

// 1. 全局 VPN 连接状态
final vpnStateProvider =
    StateNotifierProvider<VpnController, VpnConnectionState>((ref) {
      return VpnController(ref);
    });

// --- 订阅链接状态 ---
final subscriptionUrlProvider = StateProvider<String>((ref) {
  return ConfigManager.getSubscriptionUrl();
});

// --- 阶段四 4.2 新增：Mock 节点池 ---
final entryPoolProvider = StateProvider<List<ProxyNode>>((ref) {
  return ConfigManager.getEntryNodesList();
});

final exitPoolProvider = StateProvider<List<ProxyNode>>((ref) {
  return ConfigManager.getExitNodesList();
});

// --- 阶段四 4.2 新增：选中的节点状态 ---
final selectedEntryNodeProvider = StateProvider<ProxyNode?>((ref) {
  final saved = ConfigManager.getEntryNode();
  if (saved != null) return saved;
  final pool = ref.read(entryPoolProvider);
  return pool.isNotEmpty ? pool.first : null;
});

final selectedExitNodeProvider = StateProvider<ProxyNode?>((ref) {
  final saved = ConfigManager.getExitNode();
  if (saved != null) return saved;
  final pool = ref.read(exitPoolProvider);
  return pool.isNotEmpty ? pool.first : null;
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
  
  container.listen(entryPoolProvider, (previous, next) {
    ConfigManager.saveEntryNodesList(next);
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

class TrafficHistoryNotifier extends StateNotifier<List<TrafficData>> {
  TrafficHistoryNotifier(this.ref) : super([]) {
    ref.listen<AsyncValue<TrafficData>>(trafficStreamProvider, (previous, next) {
      final vpnState = ref.read(vpnStateProvider);
      if (vpnState != VpnConnectionState.connected) {
        return;
      }

      next.whenData(addTraffic);
    });

    ref.listen<VpnConnectionState>(vpnStateProvider, (previous, next) {
      if (next == VpnConnectionState.disconnected) {
        clear();
      }
    });
  }

  final Ref ref;
  static const int _maxLength = 60;

  void addTraffic(TrafficData data) {
    final nextState = [...state, data];
    if (nextState.length > _maxLength) {
      state = nextState.sublist(nextState.length - _maxLength);
      return;
    }
    state = nextState;
  }

  void clear() {
    state = [];
  }
}

final trafficHistoryProvider =
    StateNotifierProvider<TrafficHistoryNotifier, List<TrafficData>>((ref) {
      return TrafficHistoryNotifier(ref);
    });

final engineTrafficSourceProvider = StateProvider<Stream<TrafficStatus>?>(
  (ref) => null,
);

// 3. 流量数据流（只监听底层真实数据）
final trafficStreamProvider = StreamProvider<TrafficData>((ref) async* {
  final stream = ref.watch(engineTrafficSourceProvider);

  if (stream == null) {
    yield TrafficData(0, 0, DateTime.now());
    return;
  }

  try {
    await for (final status in stream) {
      yield TrafficData(
        status.up.toInt() / 1024.0,
        status.down.toInt() / 1024.0,
        DateTime.now(),
      );
    }
  } catch (_) {
    yield TrafficData(0, 0, DateTime.now());
  }
});
