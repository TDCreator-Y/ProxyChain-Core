import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vpn_state_provider.dart';

class TrafficChart extends ConsumerStatefulWidget {
  const TrafficChart({super.key});

  @override
  ConsumerState<TrafficChart> createState() => _TrafficChartState();
}

class _TrafficChartState extends ConsumerState<TrafficChart> {
  bool _isTimeout = false;
  Timer? _timer;
  VpnConnectionState _lastVpnState = VpnConnectionState.disconnected;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimeoutTimer() {
    _timer?.cancel();
    _isTimeout = false;
    _timer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _isTimeout = true;
          debugPrint('[TrafficChart] Loading timeout (3s) reached. Rendering empty chart.');
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dataPoints = ref.watch(trafficHistoryProvider);
    final vpnState = ref.watch(vpnStateProvider);

    // 监听 VPN 状态变化，重新启动 loading 计时器
    if (vpnState != _lastVpnState) {
      _lastVpnState = vpnState;
      if (vpnState == VpnConnectionState.connecting || 
         (vpnState == VpnConnectionState.connected && dataPoints.isEmpty)) {
        _startTimeoutTimer();
      } else {
        _timer?.cancel();
        _isTimeout = false;
      }
    }

    // 如果收到数据，取消超时状态
    if (dataPoints.isNotEmpty && _timer != null && _timer!.isActive) {
      _timer?.cancel();
      _isTimeout = false;
    }

    // 验证 loading 状态管理：连接中或已连接但暂无数据时显示 loading
    // 增加 3 秒超时容错，防止一直转圈
    if ((vpnState == VpnConnectionState.connecting || 
        (vpnState == VpnConnectionState.connected && dataPoints.isEmpty)) && 
        !_isTimeout) {
      return const Center(child: CircularProgressIndicator());
    }

    // 初始化占位数据，解决空数据时 fl_chart 渲染崩溃问题
    final displayData = dataPoints.isEmpty
        ? [TrafficData(0, 0, DateTime.now(), index: 0)]
        : dataPoints;

    final minX = displayData.first.index.toDouble();
    final maxX = minX + 60;

    double maxSpeed = 0;
    for (var d in displayData) {
      if (d.upSpeed > maxSpeed) maxSpeed = d.upSpeed;
      if (d.downSpeed > maxSpeed) maxSpeed = d.downSpeed;
    }
    final maxY = maxSpeed > 0 ? maxSpeed * 1.2 : 100.0; // 预留 20%，最小100

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Real-time Traffic (KB/s)',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: LineChart(
              LineChartData(
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                minX: minX,
                maxX: maxX,
                minY: 0,
                maxY: maxY,
                lineBarsData: [
                  // 上行曲线 (绿色)
                  LineChartBarData(
                    spots: displayData
                        .map(
                          (e) => FlSpot(
                            e.index.toDouble(),
                            e.upSpeed,
                          ),
                        )
                        .toList(),
                    isCurved: true,
                    color: Colors.green,
                    barWidth: 2,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          Colors.green.withOpacity(0.5),
                          Colors.green.withOpacity(0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  // 下行曲线 (蓝色)
                  LineChartBarData(
                    spots: displayData
                        .map(
                          (e) => FlSpot(
                            e.index.toDouble(),
                            e.downSpeed,
                          ),
                        )
                        .toList(),
                    isCurved: true,
                    color: Colors.blue,
                    barWidth: 2,
                    isStrokeCapRound: true,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          Colors.blue.withOpacity(0.5),
                          Colors.blue.withOpacity(0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegend(Colors.green, 'Upload'),
              const SizedBox(width: 20),
              _buildLegend(Colors.blue, 'Download'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegend(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
      ],
    );
  }
}
