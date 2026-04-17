import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/cupertino.dart';

class MachineBridgeService {
  Socket? _socket;
  Timer? _heartbeatTimer;

  // 기기와의 연결 상태를 알 수 있는 알림 변수 (UI에서 활용 가능)
  final ValueNotifier<bool> isConnected = ValueNotifier<bool>(false);

  static const String _hexKey = "734B09645723794F14B817BB6218D14E";

  void _log(String message) {
    debugPrint("[Caye] $message"); // 모든 로그에 [Caye]를 붙입니다.
  }

  // --- [여기에 추가 2: 단순 네트워크 확인 함수] ---
  Future<bool> checkNetworkOnly(String ip) async {
    int machinePort = 31255;
    try {
      _log("🚀 [Network Test] 목적지: $ip, 포트: $machinePort 접속 시도...");
      final socket = await Socket.connect(ip, machinePort, timeout: const Duration(seconds: 10));
      socket.destroy();
      _log("✅ [Network] $ip 연결 가능 확인");
      return true;
    } catch (e) {
      _log("❌ [Network] $ip 연결 불가: $e");
      return false;
    }
  }

// 1. AES-128 암호화 엔진 (새로운 규격 반영)
  Uint8List _encryptPayload(int functionCode, Map<String, dynamic> body) {
    final key = enc.Key.fromBase16(_hexKey);

    // 🚀 [수정 포인트 1] IV를 16개의 0x00으로 명확히 고정
    final iv = enc.IV(Uint8List(16));

    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));

    // A. 8바이트 타임스탬프 (Big-Endian)
    int ts = DateTime.now().millisecondsSinceEpoch;

    // 🚀 [수정 포인트 2] setUint64 사용 및 바이트 버퍼 확보
    final ByteData tsData = ByteData(8);
    tsData.setUint64(0, ts, Endian.big);
    Uint8List tsBytes = tsData.buffer.asUint8List();

    List<int> combinedData;

    // B. 데이터 결합 (0x00, 0x10 등은 JSON 제외)
    if (body.isEmpty) {
      combinedData = tsBytes.toList();
      _log("📦 [Encrypt] Only Timestamp (Code: 0x${functionCode.toRadixString(16)})");
    } else {
      String jsonString = jsonEncode(body);
      combinedData = [...tsBytes, ...utf8.encode(jsonString)];
      _log("📦 [Encrypt] TS + JSON (Code: 0x${functionCode.toRadixString(16)})");
    }

    // C. 암호화 수행
    return encrypter.encryptBytes(combinedData, iv: iv).bytes;
  }

  // 2. 체크섬 계산 (규격: 암호화된 Data Content 영역만 XOR)
  int _getChecksum(Uint8List encryptedData) {
    int cs = 0;
    for (var byte in encryptedData) cs ^= byte;
    return cs & 0xFF;
  }

  // 3. 통합 패킷 전송 함수 (새로운 11바이트+n 헤더 구조)
  Future<void> _sendPacket(String ip, int functionCode, Map<String, dynamic> body) async {
    const int machinePort = 31255;
    try {
      if (_socket == null) {
        _log("🌐 기계 접속 시도 중... (IP: $ip, Port: $machinePort)");
        _socket = await Socket.connect(ip, machinePort, timeout: const Duration(seconds: 5));
        isConnected.value = true;

        _socket!.listen(
          _handleIncomingData,
          onDone: () => _handleDisconnect(),
          onError: (e) => _handleDisconnect(),
        );

        _startHeartbeat(ip);
      }

      // A. 암호화 진행 (바디가 비어있으면 빈 문자열 전달)
      Uint8List encrypted = _encryptPayload(functionCode, body);

      final builder = BytesBuilder();
      builder.add([0xCC, 0xAA]); // Header
      builder.addByte(functionCode);
      builder.addByte(0x01); // Count
      builder.addByte(0x01); // Index

      // Data Length (2바이트 Big-Endian)
      Uint8List lenBytes = Uint8List(2)..buffer.asByteData().setUint16(0, encrypted.length, Endian.big);
      builder.add(lenBytes);

      builder.add(encrypted); // Data Content
      builder.addByte(_getChecksum(encrypted)); // Checksum
      builder.add([0xFF, 0xEE]); // Trailer

      Uint8List finalPacket = builder.toBytes();
      _socket!.add(finalPacket);
      _log("📡 [Sent] Code: 0x${functionCode.toRadixString(16)} | Data: $body");
    } catch (e) {
      _log("❌ 전송 에러: $e");
      _handleDisconnect();
    }
  }

  // --- [대표님 요청 기능별 함수들] ---
// 0x00: 하트비트/시간동기화 (규격상 body 없이 TS만 암호화해서 보냄)
  Future<void> sendTimeSyncCommand(String ip) async => await _sendPacket(ip, 0x00, {});

  // 0x20: 음료 제조
  Future<void> sendMakeCommand(String ip, String productKey, String orderNo) async {
    await _sendPacket(ip, 0x20, {
      "func": 1, // 제조 기능을 의미하는 고정값
      "params": {
        "productKey": productKey.toString(),
        "orderNo": orderNo.toString(),
      }
    });
  }

  Future<void> sendCleaningCommand(String ip) async => await _sendPacket(ip, 0x01, {"mode": 0});
  Future<void> sendRinsingCommand(String ip) async => await _sendPacket(ip, 0x10, {});
  Future<void> sendQueryStatus(String ip) async => await _sendPacket(ip, 0x31, {});

  void _startHeartbeat(String ip) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      sendTimeSyncCommand(ip);
    });
  }

  // 6. 머신에서 오는 데이터 처리 (0x24 실시간 리포트 등)
  void _handleIncomingData(Uint8List data) {
    // 수신 데이터를 16진수로 출력하여 분석 용이하게 함
    String hexResponse = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    _log("📥 [Received] $hexResponse");
  }

  void _handleDisconnect() {
    _socket?.destroy();
    _socket = null;
    _heartbeatTimer?.cancel();
    isConnected.value = false;
    _log("🔌 [Disconnected] 연결 종료");
  }

  void dispose() {
    _handleDisconnect();
  }
}