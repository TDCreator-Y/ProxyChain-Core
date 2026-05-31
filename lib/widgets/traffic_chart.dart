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
  final List<TrafficData> _dataPoints = [];
  final int _maxDataPoints = 30; // 屏幕上最多显示30秒的数据

  @override
  Widget build(BuildContext context) {
    // 监听流量数据流
    ref.listen<AsyncValue<TrafficData>>(trafficStreamProvider, (
      previous,
      next,
    ) {
      if (next.hasValue && next.value != null) {
        setState(() {
          _dataPoints.add(next.value!);
          if (_dataPoints.length > _maxDataPoints) {
            _dataPoints.removeAt(0);
          }
        });
      }
    });

    if (_dataPoints.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final minTime = _dataPoints.first.time.millisecondsSinceEpoch.toDouble();
    final maxTime = _dataPoints.last.time.millisecondsSinceEpoch.toDouble();
    // 如果数据点太少，给定一个最小的跨度避免图表报错
    final timeRange = (maxTime - minTime) > 0 ? (maxTime - minTime) : 1000.0;

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
                minX: minTime,
                maxX: minTime + timeRange,
                minY: 0,
                maxY: 2000, // 假设最大速度为 2000 KB/s，后期可动态计算
                lineBarsData: [
                  // 上行曲线 (绿色)
                  LineChartBarData(
                    spots: _dataPoints
                        .map(
                          (e) => FlSpot(
                            e.time.millisecondsSinceEpoch.toDouble(),
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
                      color: Colors.green.withOpacity(0.2),
                    ),
                  ),
                  // 下行曲线 (蓝色)
                  LineChartBarData(
                    spots: _dataPoints
                        .map(
                          (e) => FlSpot(
                            e.time.millisecondsSinceEpoch.toDouble(),
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
                      color: Colors.blue.withOpacity(0.2),
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
