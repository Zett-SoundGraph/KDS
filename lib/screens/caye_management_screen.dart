// screens/caye_management_screen.dart
import 'package:flutter/material.dart';
import '../services/machine_bridge_service.dart';

class CayeManagementScreen extends StatefulWidget {
  final String machineIp;
  final String? activeProductKey;
  final String? activeOrderNo;
  const CayeManagementScreen({
    super.key,
    required this.machineIp,
    this.activeProductKey,
    this.activeOrderNo,});

  @override
  State<CayeManagementScreen> createState() => _CayeManagementScreenState();
}

class _CayeManagementScreenState extends State<CayeManagementScreen> {
  final MachineBridgeService _service = MachineBridgeService();

  // 가상의 진행 상태 (나중에 머신 데이터와 연동)
  double _progress = 0.0;
  String _currentStatus = "Connected - Standby";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("CAYE MACHINE DASHBOARD"),
        backgroundColor: Colors.blueGrey[900],
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _service.sendQueryStatus(widget.machineIp), // 0x31
          )
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            // 1. 상단 상태 카드
            _buildStatusCard(),
            const SizedBox(height: 30),

            // 2. 실시간 모니터링 영역 (진행바)
            if (_progress > 0) _buildProgressIndicator(),
            const SizedBox(height: 30),

            // 3. 제어 섹션
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 15,
                crossAxisSpacing: 15,
                children: [
                  _controlBtn("Rinse", Icons.water_drop, Colors.cyan,
                          () => _service.sendRinsingCommand(widget.machineIp)),
                  _controlBtn("Clean", Icons.cleaning_services, Colors.orange,
                          () => _showCleaningDialog(context)),
                  _controlBtn("Status", Icons.manage_search, Colors.purple,
                          () => _service.sendQueryStatus(widget.machineIp)),
                  _controlBtn("Sync Time", Icons.sync, Colors.teal,
                          () => _service.sendTimeSyncCommand(widget.machineIp)),
                  _controlBtn("Today's Data (0x35)", Icons.insert_chart_outlined, Colors.pinkAccent,
                          () {
                        _service.sendTodayExtractionHistory(widget.machineIp);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("📡 오늘치 기록을 요청했습니다. Logcat을 확인하세요!")),
                        );
                      }),
                ],
              ),
            ),

            // 4. 하단 긴급 중지 버튼
            if (widget.activeProductKey != null && widget.activeOrderNo != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: ElevatedButton.icon(
                  onPressed: () {
                    // 🚀 실제 진행 중인 레시피 정보가 있으면 그 값으로 취소!
                    _service.sendCancelCommand(widget.machineIp, widget.activeProductKey!, widget.activeOrderNo!);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Emergency Stop command sent!")));
                  },
                  icon: const Icon(Icons.stop_circle, size: 30),
                  label: const Text("Emergency Stop", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      minimumSize: const Size(double.infinity, 70),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showCleaningDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: const Text("Select Cleaning Mode",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildModalTile("End of Day Cleaning (All)", "Cleans all internal systems.", 0),
            const Divider(color: Colors.white10),
            _buildModalTile("Coffee System Cleaning", "Cleans the coffee extraction lines.", 1),
            const Divider(color: Colors.white10),
            _buildModalTile("Milk System Cleaning", "Cleans milk nozzles and pipes.", 2),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  Widget _buildModalTile(String title, String subtitle, int mode) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 5),
      title: Text(title, style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      trailing: const Icon(Icons.play_arrow_rounded, color: Colors.orangeAccent),
      onTap: () {
        _service.sendCleaningCommand(widget.machineIp, mode: mode);
        Navigator.pop(context); // 팝업 닫기

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("🚀 Starting $title!")),
        );
      },
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.blueGrey[900],
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.blueAccent.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.coffee_maker, size: 50, color: Colors.blueAccent),
          const SizedBox(width: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("IP: ${widget.machineIp}", style: const TextStyle(color: Colors.white70)),
              Text(_currentStatus, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("Progress", style: TextStyle(color: Colors.white)),
            Text("${(_progress * 100).toInt()}%", style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(
          value: _progress,
          backgroundColor: Colors.white10,
          color: Colors.orangeAccent,
          minHeight: 15,
        ),
      ],
    );
  }

  Widget _controlBtn(String label, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 40),
            const SizedBox(height: 10),
            Text(label, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}