import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';

import '../models/order_item.dart';

class KdsSocketService {
  WebSocket? _socket;
  final String serverIp = "192.168.10.192";
  final int serverPort = 8080;

  bool _isManualClose = false; // 사용자가 의도적으로 닫았는지 여부
  bool _isReconnecting = false; // 재연결 프로세스가 진행 중인지 확인
  Timer? _reconnectTimer;
  final ValueNotifier<bool> isConnectedNotifier = ValueNotifier<bool>(false);
  // 1. [수정] 콜백 함수가 orderNo와 menuName 두 개를 받도록 변경합니다.
  Function(String orderNo, String menuName)? onPickupSignalReceived;
  Function(String status)? onStatusChanged;

  Future<void> connectToServer() async {
    // 이미 연결되어 있거나 시도 중이면 중복 실행 방지
    if (_socket?.readyState == WebSocket.open || _isReconnecting) return;

    _isManualClose = false;
    _isReconnecting = true;

    try {
      final String wsUrl = "ws://$serverIp:$serverPort";

      _socket = await WebSocket.connect(wsUrl).timeout(const Duration(seconds: 5));

      // 역할 확인 패킷 전송
      _socket!.add(jsonEncode({
        "type": "identify",
        "role": "KDS"
      }));

      _isReconnecting = false;
      isConnectedNotifier.value = true;
      // 재연결 타이머가 돌아가고 있다면 중지
      _reconnectTimer?.cancel();

      _socket!.listen(
            (data) {
          _handleMessage(data);
        },
        onDone: () {
          _handleDisconnect();
        },
        onError: (e) {
          _handleDisconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _handleDisconnect();
    }
  }

  /// 메시지 해석 로직 분리
  void _handleMessage(dynamic data) {
    try {
      final Map<String, dynamic> jsonData = jsonDecode(data.toString());
      if (jsonData['type'] == 'PICKUP_COMPLETE') {
        final String orderNo = jsonData['orderNo'].toString();
        final String menuName = jsonData['menuName']?.toString() ?? "";
        onPickupSignalReceived?.call(orderNo, menuName);
      } else if (jsonData['type'] == 'VALIDATION_MODE' || jsonData['type'] == 'CALIB_EXIT') {
        onStatusChanged?.call(jsonData['type']);
      }
    } catch (e) {
    }
  }

  void sendOrderReady(OrderItem order, String menuName, int totalOrderCount) {
    if (_socket != null && _socket!.readyState == WebSocket.open) {
      Map<String, dynamic> data = {
        "type": "ORDER_READY",
        "orderNo": order.orderNo,
        "menuName": menuName,
        "drinkCount": order.drinkCount,
        "foodCount": order.foodCount,
        "bottleCount": order.bottleCount,
        // "nickname": order.nickname ?? "",
        "nickname": "",
        "totalRequired": totalOrderCount,
        "timestamp": DateTime.now().toIso8601String(),
      };
      _socket!.add(jsonEncode(data));
      print("🚀 서버로 ORDER_READY 전송: ${order.orderNo} ($menuName)");
    } else {
      print("⚠️ 서버 연결 끊김");
    }
  }

  void _handleDisconnect() {
    _socket?.close();
    _socket = null;
    isConnectedNotifier.value = false;
    _isReconnecting = false;

    // 사용자가 앱을 종료한 것이 아니라면 재연결 시도
    if (!_isManualClose) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel(); // 기존 타이머가 있다면 취소
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      connectToServer();
    });
  }

  void dispose() {
    _isManualClose = true;
    _reconnectTimer?.cancel();
    _socket?.close();
    isConnectedNotifier.dispose();
  }

  void sendStartCalibration(double height) {
    if (_socket != null && _socket!.readyState == WebSocket.open) {
      Map<String, dynamic> data = {
        "type": "START_CALIBRATION", // 약속된 메시지 타입
        "height": height,
        "timestamp": DateTime.now().toIso8601String(),
      };
      _socket!.add(jsonEncode(data));
      print("🎯 서버로 START_CALIBRATION 신호 전송");
    } else {
      print("⚠️ 서버 연결 끊김: 신호를 보낼 수 없습니다.");
    }
  }

  // void sendFineTuneControl(String subType, {dynamic value}) {
  //   if (_socket?.readyState == WebSocket.open) {
  //     _socket!.add(jsonEncode({
  //       "type": "FINE_TUNE_CONTROL",
  //       "subType": subType,
  //       "value": value,
  //       "timestamp": DateTime.now().toIso8601String(),
  //     }));
  //   }
  // }
}