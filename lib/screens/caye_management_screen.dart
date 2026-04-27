// screens/caye_management_screen.dart
import 'package:flutter/material.dart';
import '../services/machine_bridge_service.dart';

class CayeManagementScreen extends StatefulWidget {
  final String machineIp;
  const CayeManagementScreen({super.key, required this.machineIp});

  @override
  State<CayeManagementScreen> createState() => _CayeManagementScreenState();
}

class _CayeManagementScreenState extends State<CayeManagementScreen> {
  final MachineBridgeService _service = MachineBridgeService();

  // 가상의 진행 상태 (나중에 머신 데이터와 연동)
  double _progress = 0.0;
  String _currentStatus = "연결됨 - 대기 중";

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
                  _controlBtn("기기 헹굼", Icons.water_drop, Colors.cyan,
                          () => _service.sendRinsingCommand(widget.machineIp)),
                  _controlBtn("기기 세척", Icons.cleaning_services, Colors.orange,
                          () => _showCleaningDialog(context)),
                  _controlBtn("상태 조회", Icons.manage_search, Colors.purple,
                          () => _service.sendQueryStatus(widget.machineIp)),
                  _controlBtn("시간 동기화", Icons.sync, Colors.teal,
                          () => _service.sendTimeSyncCommand(widget.machineIp)),
                ],
              ),
            ),

            // 4. 하단 긴급 중지 버튼
            if (_progress > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: ElevatedButton.icon(
                  onPressed: () {
                    // 🚀 취소 로직 (현재 수행 중인 레시피 정보 필요)
                    _service.sendCancelCommand(widget.machineIp, "1", "CANCEL_REQ");
                  },
                  icon: const Icon(Icons.stop_circle, size: 30),
                  label: const Text("작업 즉시 취소", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
        title: const Text("세척 모드 선택",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildModalTile("마감 세척 (전체)", "기기의 모든 시스템을 세척합니다.", 0),
            const Divider(color: Colors.white10),
            _buildModalTile("커피 시스템 세척", "커피 추출 라인을 집중 세척합니다.", 1),
            const Divider(color: Colors.white10),
            _buildModalTile("우유 시스템 세척", "우유 노즐 및 관로를 세척합니다.", 2),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("취소", style: TextStyle(color: Colors.white54)),
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
          SnackBar(content: Text("🚀 $title 시작!")),
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
            const Text("작업 진행률", style: TextStyle(color: Colors.white)),
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