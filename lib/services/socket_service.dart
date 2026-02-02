import 'dart:io';
import 'dart:convert';
import 'dart:async';

class KdsSocketService {
  WebSocket? _socket;
  final String serverIp = "192.168.10.192";
  final int serverPort = 8080;

  // 1. [수정] 콜백 함수가 orderNo와 menuName 두 개를 받도록 변경합니다.
  Function(String orderNo, String menuName)? onPickupSignalReceived;

  final StreamController<bool> _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;

  Future<void> connectToServer() async {
    try {
      final String wsUrl = "ws://$serverIp:$serverPort";
      _socket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 5));
      _socket!.add(jsonEncode({
        "type": "identify",
        "role": "KDS"
      }));
      print("✅ 픽업 테이블 서버(WebSocket) 연결 성공!");
      _connectionController.add(true);

      _socket!.listen(
            (data) {
          print("📩 서버 응답: $data");
          try {
            final Map<String, dynamic> jsonData = jsonDecode(data.toString());

            if (jsonData['type'] == 'PICKUP_COMPLETE') {
              // 2. [수정] 서버가 보낸 JSON에서 orderNo와 menuName을 모두 추출합니다.
              final String orderNo = jsonData['orderNo'].toString();
              final String menuName = jsonData['menuName']?.toString() ?? "";

              // 3. [수정] 두 정보를 모두 콜백으로 넘겨줍니다.
              onPickupSignalReceived?.call(orderNo, menuName);
            }
          } catch (e) {
            print("신호 해석 에러: $e");
          }
        },
        onDone: () => _handleDisconnect(),
        onError: (e) => _handleDisconnect(),
      );
    } catch (e) {
      print("❌ 웹소켓 연결 실패: $e");
      _connectionController.add(false);
    }
  }

  void sendOrderReady(String orderNo, String menuName) {
    if (_socket != null && _socket!.readyState == WebSocket.open) {
      Map<String, dynamic> data = {
        "type": "ORDER_READY",
        "orderNo": orderNo,
        "menuName": menuName,
        "timestamp": DateTime.now().toIso8601String(),
      };
      _socket!.add(jsonEncode(data));
      print("🚀 서버로 ORDER_READY 전송: $orderNo ($menuName)");
    } else {
      print("⚠️ 서버 연결 끊김");
    }
  }

  void _handleDisconnect() {
    _socket?.close();
    _socket = null;
    _connectionController.add(false);
    print("🔌 서버 연결 종료");
  }

  void dispose() {
    _socket?.close();
    _connectionController.close();
  }
}