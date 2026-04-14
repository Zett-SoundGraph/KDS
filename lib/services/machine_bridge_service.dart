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

  // 1. AES-128 암호화 엔진 (대표님 지침 100% 반영)
  Uint8List _encryptPayload(String jsonString) {
    // 💡 실제 기기 도착 시 CAYE에서 제공한 16바이트 키로 반드시 교체하세요!
    final key = enc.Key.fromUtf8("CAYE_KEY_16BYTES");
    final iv = enc.IV.fromLength(16); // 16개의 0
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));

    // 8바이트 타임스탬프 (ms) 생성 및 결합
    int ts = DateTime.now().millisecondsSinceEpoch;
    Uint8List tsBytes = Uint8List(8)..buffer.asByteData().setInt64(0, ts, Endian.big);
    Uint8List jsonBytes = Uint8List.fromList(utf8.encode(jsonString));

    return encrypter.encryptBytes([...tsBytes, ...jsonBytes], iv: iv).bytes;
  }

  // 2. XOR 체크섬 계산
  int _getChecksum(List<int> p) {
    int cs = 0;
    for (int i = 2; i < p.length; i++) cs ^= p[i];
    return cs & 0xFF;
  }

  // 3. 통합 패킷 전송 함수 (중복 코드 방지)
  Future<void> _sendPacket(String ip, int functionCode, Map<String, dynamic> body) async {
    try {
      if (_socket == null) {
        _socket = await Socket.connect(ip, 5000, timeout: const Duration(seconds: 2));
        isConnected.value = true;

        // 👂 머신이 보내는 데이터를 듣는 리스너 시작 (0x24 등 수신)
        _socket!.listen(
          _handleIncomingData,
          onDone: () => _handleDisconnect(),
          onError: (e) => _handleDisconnect(),
        );

        // 💓 연결 성공 시 하트비트(1분 주기) 시작
        _startHeartbeat(ip);
      }

      String jsonBody = jsonEncode(body);
      Uint8List encrypted = _encryptPayload(jsonBody);

      // 패킷 조립: [Header] [Code] [Len] [Data] [CS] [Trailer]
      List<int> packet = [0xCC, 0xAA, functionCode, encrypted.length, ...encrypted];
      packet.add(_getChecksum(packet));
      packet.addAll([0xFF, 0xEE]);

      _socket!.add(packet);
      debugPrint("📡 [Sent] Code: 0x${functionCode.toRadixString(16).toUpperCase()} | Data: $jsonBody");
    } catch (e) {
      debugPrint("❌ [Error] 전송 실패: $e");
      _handleDisconnect();
    }
  }

  // --- [대표님 요청 기능별 함수들] ---

  // 4-1. 시간 동기화 및 하트비트 (0x00)
  Future<void> sendTimeSyncCommand(String ip) async {
    await _sendPacket(ip, 0x00, {"timestamp": DateTime.now().millisecondsSinceEpoch});
  }

  // 4-2. 음료 제조 명령 (0x20)
  Future<void> sendMakeCommand(String ip, String productKey, String orderNo) async {
    await _sendPacket(ip, 0x20, {"productKey": productKey, "orderNo": orderNo});
  }

  // 4-3. 세척 (0x01) / 헹굼 (0x10) / 상태조회 (0x31)
  Future<void> sendCleaningCommand(String ip) async => await _sendPacket(ip, 0x01, {});
  Future<void> sendRinsingCommand(String ip) async => await _sendPacket(ip, 0x10, {});
  Future<void> sendQueryStatus(String ip) async => await _sendPacket(ip, 0x31, {});

  // --- [시스템 관리 로직] ---

  // 5. 하트비트 타이머 (1분 주기)
  void _startHeartbeat(String ip) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      sendTimeSyncCommand(ip);
    });
  }

  // 6. 머신에서 오는 데이터 처리 (0x24 실시간 리포트 등)
  void _handleIncomingData(Uint8List data) {
    // 💡 여기서 받은 데이터를 복호화하여 0x24(압력, 중량) 데이터를 추출합니다.
    // 현재는 로그만 찍지만, 나중에 이 데이터를 픽업 테이블 서버로 쏘면 됩니다.
    debugPrint("📥 [Received from Machine] Raw Bytes Length: ${data.length}");
  }

  void _handleDisconnect() {
    _socket?.destroy();
    _socket = null;
    _heartbeatTimer?.cancel();
    isConnected.value = false;
    debugPrint("🔌 [Disconnected] 머신과의 연결이 종료되었습니다.");
  }

  void dispose() {
    _handleDisconnect();
  }
}