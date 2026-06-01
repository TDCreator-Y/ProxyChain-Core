import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_app/src/rust/api/proxy.dart';
import '../services/config_manager.dart';
import '../utils/privilege_util.dart';

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
      // 检查提权逻辑：如果没有管理员/root权限，PrivilegeUtil会尝试弹窗并重启App，当前进程随即终止。
      final isElevated = await PrivilegeUtil.checkAndElevate();
      if (!isElevated) {
        // App 正在重启，中断当前流程
        return;
      }

      final trafficStream = startEngine(
        entryNode: entryNode,
        exitNode: exitNode,
      );
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
  final int index;

  TrafficData(this.upSpeed, this.downSpeed, this.time, {this.index = 0});

  TrafficData copyWith({
    double? upSpeed,
    double? downSpeed,
    DateTime? time,
    int? index,
  }) {
    return TrafficData(
      upSpeed ?? this.upSpeed,
      downSpeed ?? this.downSpeed,
      time ?? this.time,
      index: index ?? this.index,
    );
  }
}

class TrafficHistoryNotifier extends StateNotifier<List<TrafficData>> {
  TrafficHistoryNotifier(this.ref) : super([]);

  final Ref ref;
  static const int _maxLength = 60;
  int _counter = 0;

  void addTraffic(TrafficData data) {
    final newData = data.copyWith(index: _counter++);
    state = [...state.skip(state.length >= _maxLength ? 1 : 0), newData];
  }

  void clear() {
    state = [];
    _counter = 0;
  }
}

final trafficHistoryProvider =
    StateNotifierProvider<TrafficHistoryNotifier, List<TrafficData>>((ref) {
      final notifier = TrafficHistoryNotifier(ref);
      
      ref.listen<AsyncValue<TrafficData>>(trafficStreamProvider, (previous, next) {
        final vpnState = ref.read(vpnStateProvider);
        if (vpnState == VpnConnectionState.connected) {
          next.whenData(notifier.addTraffic);
        }
      });

      ref.listen<VpnConnectionState>(vpnStateProvider, (previous, next) {
        if (next == VpnConnectionState.disconnected) {
          notifier.clear();
        }
      });
      
      return notifier;
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
    // 捕获并打印底层数据流的异常，排查请求/推送链路中的异常信息
    await for (final status in stream) {
      yield TrafficData(
        status.up.toInt() / 1024.0,
        status.down.toInt() / 1024.0,
        DateTime.now(),
      );
    }
  } catch (error, stackTrace) {
    // 打印底层 Rust 数据流推送异常，便于排查时序和格式错误
    debugPrint('[trafficStreamProvider] Error in traffic stream: $error\n$stackTrace');
    yield TrafficData(0, 0, DateTime.now());
  }
});
