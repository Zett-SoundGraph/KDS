import 'dart:async';
import 'package:flutter/material.dart';
import '../services/machine_bridge_service.dart';
import '../models/order_item.dart'; // 🚀 SubItem 참조를 위해 추가

void showExtractionMonitor(
    BuildContext context,
    MachineBridgeService service,
    String menuName, {
      required String machineIp,
      required String productKey,
      required String orderNo,
      required SubItem subItem, // 🚀 현재 진행 상태를 가진 subItem 필수 전달
      Function? onComplete,
      Function? onCancel,
    }) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ExtractionMonitorContent(
      service: service,
      menuName: menuName,
      machineIp: machineIp,
      productKey: productKey,
      orderNo: orderNo,
      subItem: subItem, // 🚀 전달
      onComplete: onComplete,
      onCancel: onCancel,
    ),
  );
}

class _ExtractionMonitorContent extends StatefulWidget {
  final MachineBridgeService service;
  final String menuName;
  final String machineIp;
  final String productKey;
  final String orderNo;
  final SubItem subItem; // 🚀 추가
  final Function? onComplete;
  final Function? onCancel;

  const _ExtractionMonitorContent({
    required this.service,
    required this.menuName,
    required this.machineIp,
    required this.productKey,
    required this.orderNo,
    required this.subItem, // 🚀 추가
    this.onComplete,
    this.onCancel,
  });

  @override
  State<_ExtractionMonitorContent> createState() => _ExtractionMonitorContentState();
}

class _ExtractionMonitorContentState extends State<_ExtractionMonitorContent> {
  // 🚀 초기값을 subItem에서 가져옵니다. (중요!)
  late List<String> _logs;
  late double _progress;
  late String _currentStage;
  late Color _themeColor;
  late bool _isFinished;
  late bool _isCancelled;
  late bool _isError;
  late String? _errorCode;

  StreamSubscription<ExtractionProgress>? _subscription;

  @override
  void initState() {
    super.initState();

    // 🚀 [핵심 1] 다이얼로그가 열리는 순간, subItem에 저장된 백그라운드 데이터를 복사합니다.
    _logs = List.from(widget.subItem.logs);
    _progress = widget.subItem.progress;
    _currentStage = widget.subItem.currentStage;
    _isFinished = widget.subItem.status == OrderStatus.ready;
    _isCancelled = false;
    _isError = widget.subItem.isError;
    _errorCode = widget.subItem.errorCode;
    _themeColor = _isError ? Colors.redAccent : (_isFinished ? Colors.greenAccent : Colors.orangeAccent);

    // 🚀 [핵심 2] 다이얼로그가 떠 있는 동안에도 실시간 데이터를 수신하여 화면을 갱신합니다.
    _subscription = widget.service.extractionStream.listen((progress) {
      if (!_isFinished && !_isCancelled && !_isError) {
        _updateState(progress);
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // UI 코드는 이전과 동일하므로 생략 (변수명 동일)
    return AlertDialog(
      backgroundColor: Colors.grey[900],
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: BorderSide(color: _themeColor.withOpacity(0.5)),
      ),
      title: Row(
        children: [
          Text(widget.menuName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          const Spacer(),
          if (_isError) const Icon(Icons.error_outline, color: Colors.redAccent),
          if (_isFinished) const Icon(Icons.check_circle_outline, color: Colors.greenAccent),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progress,
                minHeight: 15,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(_themeColor),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_currentStage, style: TextStyle(color: _themeColor, fontWeight: FontWeight.bold)),
                Text("${(_progress * 100).toInt()}%", style: TextStyle(color: _themeColor)),
              ],
            ),

            if (_isError && _errorCode != null)
              Container(
                margin: const EdgeInsets.only(top: 15),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Error Code: $_errorCode\n(Please check and try again)",
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),

            const Divider(color: Colors.white24, height: 30),
            SizedBox(
              height: 150, // 로그 시인성을 위해 높이 약간 조절
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (context, i) => Text(_logs[i],
                    style: TextStyle(color: i == 0 ? _themeColor : Colors.white54, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        Row(
          children: [
            if (!_isFinished && !_isCancelled && !_isError)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: OutlinedButton(
                    onPressed: () => _requestCancel(),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: const Text("Stop Brewing", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),

            Expanded(
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context), // 조건 없이 바로 닫기 가능
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isFinished
                      ? Colors.green
                      : (_isError ? Colors.red[900] : Colors.blueGrey[800]), // 제조 중일 땐 색상 변경
                  padding: const EdgeInsets.symmetric(vertical: 15),
                ),
                child: Text(
                    (_isFinished || _isCancelled || _isError) ? "OK" : "Close (Continue)",
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _requestCancel() {
    widget.service.sendCancelCommand(widget.machineIp, widget.productKey, widget.orderNo);

    setState(() {
      _isCancelled = true; // 스트림 업데이트 중단
      _logs.insert(0, "🛑 Cancelled by user");
      _currentStage = "Cancellation Complete";

      // 🚀 [추가 5] 즉시 진행률을 0으로 초기화하고 제조 상태를 해제함
      widget.subItem.progress = 0.0;
      widget.subItem.isExtracting = false;
      widget.subItem.isError = false;
      widget.subItem.status = OrderStatus.pending;
    });

    // 🚀 [추가 6] 메인 화면에 "취소됐으니 큐에서 빼라"고 알림
    if (widget.onCancel != null) {
      widget.onCancel!();
    }
  }

  // 🚀 _updateState 로직은 이전과 동일하지만, 이제 다이얼로그 전용 로컬 변수를 업데이트합니다.
  void _updateState(ExtractionProgress progress) {
    final data = progress.data;
    String? newLog;

    if (!mounted) return;

    setState(() {
      if (progress.code == 0x24) {
        final double currentTime = (data['extractTime'] ?? 0).toDouble();
        final double targetTime = (data['targetExtractTime'] ?? 1).toDouble();
        final double powder = (data['powderWeight'] ?? 0).toDouble();
        final double targetPowder = (data['targetPowderWeight'] ?? 1).toDouble();

        if (currentTime > 0) {
          _progress = (0.3 + (currentTime / targetTime) * 0.65).clamp(0.0, 0.99);
          _currentStage = "에스프레소 추출 중...";
          widget.subItem.progress = _progress;
          widget.subItem.currentStage = _currentStage;
          newLog = "💧 ${data['coffeeWaterQuantity']}ml / 🌡️ ${data['boilerTemp']}°C / ⚖️ ${data['coffeeWeight']}g";
        } else if (powder > 0) {
          _progress = ((powder / targetPowder) * 0.3).clamp(0.0, 0.3);
          _currentStage = "Grinding Beans...";
          newLog = "🫘 Grinding beans: $powder / $targetPowder g";
        } else {
          // 🚀 [추가] 다이얼로그에도 물 투출 단계 추가
          _progress = 0.05;
          _currentStage = "Dispensing Water...";
          widget.subItem.progress = _progress;
          widget.subItem.currentStage = _currentStage;
          newLog = "💧 Dispensing Water / Preparing...";
        }
      }
      else if (progress.code == 0x22) {
        final int status = data['status'] ?? 0;
        switch (status) {
          case 3:
            if (!_isFinished) {
              _isFinished = true;
              _progress = 1.0;
              _currentStage = "✅ Brewing Complete";
              widget.subItem.progress = 1.0;
              widget.subItem.status = OrderStatus.ready;
              widget.subItem.isExtracting = false;
              _themeColor = Colors.greenAccent;
              newLog = "✅ The beverage has been successfully brewed.";
              if (widget.onComplete != null) {
                WidgetsBinding.instance.addPostFrameCallback((_) => widget.onComplete!());
              }
            }
            break;
          case 99:
          case 6:
            _isError = true;
            _themeColor = Colors.redAccent;
            _currentStage = "❌ Brewing Failed";
            final dynamic errorData = data['errorCode'];
            _errorCode = (errorData is List && errorData.isNotEmpty) ? errorData.join(", ") : errorData?.toString() ?? "Error";
            newLog = "❌ Error: $_errorCode";
            break;
        }
      }

      if (newLog != null && (_logs.isEmpty || _logs.first != newLog)) {
        _logs.insert(0, newLog!);
        if (widget.subItem.logs.isEmpty || widget.subItem.logs.first != newLog) {
          widget.subItem.logs.insert(0, newLog!);
        }
      }
    });
  }
}