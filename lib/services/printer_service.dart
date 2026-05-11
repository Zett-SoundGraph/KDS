import 'dart:async';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screenshot/screenshot.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;


class PrinterService {
  static final PrinterService _instance = PrinterService._internal();
  factory PrinterService() => _instance;
  PrinterService._internal();
  // MainActivity.kt에서 설정한 채널명과 정확히 일치해야 합니다.
  static const _statusChannel = EventChannel('com.sg.kds/printer_status');
  static const _actionChannel = MethodChannel('com.sg.kds/printer_action');

  final ScreenshotController _screenshotController = ScreenshotController();
  // 라벨 상태를 실시간으로 알려줄 스트림
  StreamSubscription? _statusSubscription;

  // 라벨 상태 변경 시 실행할 콜백 함수 저장
  void listenToLabels({
    required Function() onDetached, // 라벨이 떼어졌을 때
    required Function() onAttached, // 라벨이 다시 붙었을 때 (출력 직후 등)
  }) {
    _statusSubscription?.cancel(); // 기존 구독이 있다면 취소

    _statusSubscription = _statusChannel.receiveBroadcastStream().listen((event) {
      if (event == "DETACHED") {
        print("📢 [Printer] 라벨이 제거되었습니다.");
        onDetached();
      } else if (event == "ATTACHED") {
        print("📢 [Printer] 라벨이 프린터에 감지되었습니다.");
        onAttached();
      }
    }, onError: (error) {
      print("❌ [Printer] 센서 에러 발생: $error");
    });
  }

  Future<void> printTest(List<String> menus) async {
    try {
      final stopWatch = Stopwatch()..start();

      // 🚀 메뉴 리스트를 arguments로 전달
      await _actionChannel.invokeMethod('printTestLabel', menus);

      log("⏱️ [텍스트] 총 소요 시간: ${stopWatch.elapsedMilliseconds}ms");
      stopWatch.stop();
    } on PlatformException catch (e) {
      log("❌ 텍스트 인쇄 에러: ${e.message}");
    }
  }

  CapabilityProfile? _cachedProfile;

  // 🚀 앱 시작 시나 서비스 초기화 때 한 번만 호출해두세요.
  Future<void> initProfile() async {
    try {
      _cachedProfile = await CapabilityProfile.load();
      log("✅ 프로필 로드 완료");
    } catch (e) {
      log("❌ 프로필 로드 실패: $e");
    }
  }

  Future<void> printImageLabel(Widget widgetToPrint) async {
    final totalWatch = Stopwatch()..start();

    // 1단계: 위젯 캡처 시간
    final step1 = Stopwatch()..start();
    Uint8List? capturedImage = await _screenshotController.captureFromWidget(
      Container(
        width: 384, // 🚀 SRP-S200의 표준 가로 도트 수 (58mm = 384 dots)
        color: Colors.white,
        child: widgetToPrint,
      ),
      pixelRatio: 1.0, // 🚀 1픽셀을 1도트로 1:1 매칭 (배율 확대 방지)
      delay: const Duration(milliseconds: 100),
    );
    print("⏱️ 1단계(캡처): ${step1.elapsedMilliseconds}ms");

    // 2단계: 이미지 디코딩 시간
    final step2 = Stopwatch()..start();
    final img.Image? decodedImage = img.decodeImage(capturedImage!);
    print("⏱️ 2단계(디코딩): ${step2.elapsedMilliseconds}ms");

    // 3단계: 래스터 변환 시간 (여기가 핵심!) 🚀
    final step3 = Stopwatch()..start();
    _cachedProfile ??= await CapabilityProfile.load();
    final generator = Generator(PaperSize.mm58, _cachedProfile!);

    List<int> bytes = [];
    bytes += generator.reset();
    bytes += generator.image(decodedImage!, align: PosAlign.center);

    print("⏱️ 3단계(래스터변환): ${step3.elapsedMilliseconds}ms");

    // 4단계: 네이티브 전송 시간
    final step4 = Stopwatch()..start();
    await _actionChannel.invokeMethod('printImageLabel', Uint8List.fromList(bytes));
    print("⏱️ 4단계(네이티브전송): ${step4.elapsedMilliseconds}ms");

    print("🏁 총 소요 시간: ${totalWatch.elapsedMilliseconds}ms");
  }

  void dispose() {
    _statusSubscription?.cancel();
  }

  Future<void> debugPrinterHardware() async {
    try {
      await _actionChannel.invokeMethod('checkHardware');
      print("🔎 하드웨어 체크 요청을 보냈습니다. 로그캣(Logcat)을 확인하세요.");
    } catch (e) {
      print("❌ 하드웨어 체크 에러: $e");
    }
  }
}