import 'dart:io';
import 'dart:convert';
import 'dart:async';

class KdsSocketService {
  WebSocket? _socket;
  final String serverIp = "192.168.10.192";
  final int serverPort = 8080;
  Function(String orderNo)? onPickupSignalReceived;
  final StreamController<bool> _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;

  // 서버 연결 함수 (WebSocket 방식)
  Future<void> connectToServer() async {
    try {
      // ws://192.168.10.192:8080 형식으로 접속해야 합니다.
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
            // 서버에서 PICKUP_COMPLETE 신호가 왔을 때
            if (jsonData['type'] == 'PICKUP_COMPLETE') {
              final String orderNo = jsonData['orderNo'].toString();
              // 콜백 함수 실행
              onPickupSignalReceived?.call(orderNo);
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

  // JSON 데이터 전송
  void sendOrderReady(String orderNo, String menuName) {
    if (_socket != null && _socket!.readyState == WebSocket.open) {
      Map<String, dynamic> data = {
        "type": "ORDER_READY",
        "orderNo": orderNo,
        "menuName": menuName,
        "timestamp": DateTime.now().toIso8601String(),
      };

      String jsonMessage = jsonEncode(data);
      _socket!.add(jsonMessage); // WebSocket은 write 대신 add를 주로 씁니다.

      print("🚀 서버로 JSON 전송 완료: $jsonMessage");
    } else {
      print("⚠️ 서버 연결 끊김. 재연결을 시도하세요.");
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