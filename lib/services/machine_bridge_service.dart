import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/cupertino.dart';

class ExtractionProgress {
  final int code;
  final Map<String, dynamic> data;
  ExtractionProgress(this.code, this.data);
}

class MachineBridgeService {
  Socket? _socket;
  Timer? _heartbeatTimer;

  // 기기와의 연결 상태를 알 수 있는 알림 변수 (UI에서 활용 가능)
  final ValueNotifier<bool> isConnected = ValueNotifier<bool>(false);

  static const String _hexKey = "734B09645723794F14B817BB6218D14E";

  void _log(String message) {
    // 긴 로그를 800자씩 끊어서 전체 출력하는 로직
    if (message.length > 800) {
      int start = 0;
      while (start < message.length) {
        int end = start + 800;
        if (end > message.length) end = message.length;
        debugPrint("[Caye] ${message.substring(start, end)}");
        start = end;
      }
    } else {
      debugPrint("[Caye] $message");
    }
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

  String? _decryptPayload(Uint8List encryptedData) {
    try {
      final key = enc.Key.fromBase16(_hexKey);
      final iv = enc.IV(Uint8List(16)); // 고정 Zero IV
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));

      // 1. 복호화 실행
      final decryptedBytes = encrypter.decryptBytes(enc.Encrypted(encryptedData), iv: iv);

      // 2. 앞의 8바이트(타임스탬프) 제거 후 나머지 JSON 파싱
      // 머신의 응답도 [8바이트 TS] + [JSON] 구조입니다.
      if (decryptedBytes.length <= 8) return null;

      final jsonBytes = decryptedBytes.sublist(8);
      return utf8.decode(jsonBytes);
    } catch (e) {
      _log("❌ 복호화 실패: $e");
      return null;
    }
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


  // Future<void> sendTimeSyncCommand(String ip) async {
  //   // 테스트하고 싶은 레시피 번호를 적으세요.
  //   String testProductKey = "1";
  //
  //   _log("🧪 [Test] 0x23(제조가능조회) 테스트 시작...");
  //   await _sendPacket(ip, 0x32, {"productKey": testProductKey});
  //
  //   // 0x32도 바로 확인해보고 싶다면 아래 주석을 해제하세요.
  //   // 너무 빨리 보내면 패킷이 꼬일 수 있으니 1초 정도 간격을 둡니다.
  //   /*
  //   await Future.delayed(const Duration(seconds: 1));
  //   _log("🧪 [Test] 0x32(제조가능조회 - 부록버전) 테스트 시작...");
  //   await _sendPacket(ip, 0x32, {"productKey": testProductKey});
  //   */
  //
  //   _log("💡 0x23과 0x32의 응답 로그([Decrypted])를 비교해 보세요.");
  // }

  // 0x20: 음료 제조
  Future<void> sendMakeCommand(String ip, String productKey, String orderNo) async {
    await _sendPacket(ip, 0x20, {
      "func": 1, // 제조 기능을 의미하는 고정값
      "params": {
        "orderNo": orderNo.toString(),
        "productKey": productKey.toString(),
      }
    });
  }

  Future<void> sendCheckAvailability(String ip, String productKey) async {
    await _sendPacket(ip, 0x23, {
      "productKey": productKey
    });
  }

  Future<void> sendCleaningCommand(String ip, {int mode = 0}) async {
    await _sendPacket(ip, 0x01, {"mode": mode});
  }
  Future<void> sendRinsingCommand(String ip) async => await _sendPacket(ip, 0x10, {});
  Future<void> sendQueryStatus(String ip) async => await _sendPacket(ip, 0x31, {});

  Future<void> sendTodayExtractionHistory(String ip) async {
    DateTime now = DateTime.now();
    // 오늘 자정 (00:00:00) 구하기
    DateTime startOfToday = DateTime(now.year, now.month, now.day);

    int startTs = startOfToday.millisecondsSinceEpoch; // 밀리초 단위 Unix Timestamp
    int endTs = now.millisecondsSinceEpoch;

    await _sendPacket(ip, 0x35, {
      "startTs": startTs,
      "endTs": endTs,
    });

    _log("📡 [Test] 0x35 오늘 추출 기록 조회 요청 (Start: $startTs, End: $endTs)");
  }

  void _startHeartbeat(String ip) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      sendTimeSyncCommand(ip);
    });
  }

  final StreamController<ExtractionProgress> _extractionStreamController =
  StreamController<ExtractionProgress>.broadcast();
  Stream<ExtractionProgress> get extractionStream => _extractionStreamController.stream;

  // 6. 머신에서 오는 데이터 처리 (0x24 실시간 리포트 등)
  void _handleIncomingData(Uint8List data) {
    if (data.length < 13) return; // 헤더(2) + 코드(1) + 카운트(1) + 인덱스(1) + 길이(2) + 체크섬(1) + 트레일러(2) = 최소 10~11바이트 이상

    // 헤더 CC AA 확인 및 데이터 길이 추출
    int functionCode = data[2];
    int dataLength = ByteData.sublistView(data, 5, 7).getUint16(0, Endian.big);

    // 암호화된 본문(Data Content) 추출
    Uint8List encryptedBody = data.sublist(7, 7 + dataLength);

    // 복호화 시도
    String? jsonResponse = _decryptPayload(encryptedBody);

    if (jsonResponse != null) {
      final decoded = jsonDecode(jsonResponse);
      if (functionCode == 0x24 || functionCode == 0x22 || functionCode == 0x20 || functionCode == 0x23 || functionCode == 0x35) {
        _extractionStreamController.add(ExtractionProgress(functionCode, decoded));
      }
      _log("📥 [Decrypted] Code: 0x${functionCode.toRadixString(16)} | Data: $jsonResponse");

      // 💡 여기서 전역 상태 관리자나 알림을 통해 UI에 데이터 전달
      // 예: _statusStreamController.add({'code': functionCode, 'data': jsonDecode(jsonResponse)});
    }
  }

  // 🚀 [추가] 제조 취소 명령 (0x20, func: 0)
  Future<void> sendCancelCommand(String ip, String productKey, String orderNo) async {
    await _sendPacket(ip, 0x20, {
      "func": 0, // 취소
      "params": {
        "productKey": productKey,
        "orderNo": orderNo,
      }
    });
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