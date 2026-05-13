import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, KeyDownEvent, LogicalKeyboardKey, HardwareKeyboard, Uint8List, MethodChannel; // CSV 로드용
import 'package:csv/csv.dart'; // CSV 파싱용
import 'package:kds/screens/caye_management_screen.dart';
import '../components/extraction_monitor_dialog.dart';
import '../components/order_card_widget.dart';
import '../models/manufacturing_queue_item.dart';
import '../models/order_item.dart';
import '../services/machine_bridge_service.dart';
import '../services/recipe_manager.dart';
import '../services/socket_service.dart';
import '../services/test_name_provider.dart';
import '../services/printer_service.dart';
import 'package:usb_serial/usb_serial.dart';

class KdsMainScreen extends StatefulWidget {
  const KdsMainScreen({super.key});

  @override
  State<KdsMainScreen> createState() => _KdsMainScreenState();
}

class _KdsMainScreenState extends State<KdsMainScreen> {
  // 1. 소켓 서비스 인스턴스 생성
  final KdsSocketService _socketService = KdsSocketService();
  final PageController _pageController = PageController();
  final MachineBridgeService _machineService = MachineBridgeService();

  List<OrderItem> _orders = [];
  bool _isLoading = true;
  int _currentPage = 0;

  bool _isCalibOverlayVisible = false;

  final List<Widget> _printQueue = [];
  bool _isLabelAttached = false;
  bool _isPrinting = false;

  final PrinterService _printerService = PrinterService();
  // final TextEditingController _hiddenInputController = TextEditingController();
  // final FocusNode _hiddenFocusNode = FocusNode();
  String _scanBuffer = "";

  static const MethodChannel _scannerChannel = MethodChannel('com.sg.kds/scanner');

  StreamSubscription? _extractionSub;

  @override
  void initState() {
    super.initState();
    _printerService.listenToLabels(
      onDetached: () {
        print("📢 [확인] 프린터에서 라벨이 제거되었습니다.");
        _isLabelAttached = false;
        _processPrintQueue();
      },
      onAttached: () {
        print("📢 [확인] 프린터에 라벨이 감지되었습니다.");
        _isLabelAttached = true;
      },
    );
    _socketService.connectToServer();
    //_loadCsvData();
    _loadMockData();
    RecipeManager().loadRecipeCsv();

    _socketService.onStatusChanged = (status) {
      if (!mounted) return;
      setState(() {
        if (status == "VALIDATION_MODE") {
          _isCalibOverlayVisible = true;
        } else if (status == "CALIB_EXIT") {
          _isCalibOverlayVisible = false;
        }
      });
    };

    // 수정된 부분: orderNo뿐만 아니라 menuName도 함께 받습니다.
    _socketService.onPickupSignalReceived = (orderNo, menuName) {
      if (!mounted) return;

      setState(() {
        // [핵심] 해당 주문 번호를 가진 카드를 KDS 화면에서 즉시 통째로 제거합니다.
        _orders.removeWhere((order) => order.orderNo == orderNo);
      });

      // 알림 표시 (선택 사항)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("$menuName for Order $orderNo picked up!"),
          duration: const Duration(seconds: 1),
        ),
      );
    };
    // _machineService.extractionStream.listen((progressData) {
    //   _updateGlobalExtractionState(progressData);
    // });
    //_startUsbHeartbeat();

    // Future.delayed(Duration.zero, () => _hiddenFocusNode.requestFocus());
    // _hiddenFocusNode.addListener(() {
    //   if (_hiddenFocusNode.hasFocus) {
    //     debugPrint("🟢 [CCTV] 텍스트창 포커스 획득! (스캔 대기 중)");
    //   } else {
    //     debugPrint("🔴 [CCTV] 텍스트창 포커스 잃음! (이때 스캔하면 인식 안 됨)");
    //   }
    // });
    _scannerChannel.setMethodCallHandler((call) async {
      if (call.method == 'onScan') {
        String scannedData = call.arguments.toString();
        debugPrint("🎯 [안드로이드 직통] 바코드 수신: $scannedData");
        _handleBarcodeScan(scannedData); // 파싱 함수로 전달
      }
    });
    _extractionSub = _machineService.extractionStream.listen((progressData) {
      _updateGlobalExtractionState(progressData);
    });
    //HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  Future<void> _processPrintQueue() async {
    if (_printQueue.isEmpty) return; // 대기열이 없으면 종료

    // 이미 인쇄 중이거나, 라벨이 아직 프린터에 매달려 있으면 대기!
    if (_isPrinting || _isLabelAttached) {
      debugPrint("⚠️ 프린터 바쁨 (인쇄중: $_isPrinting, 부착됨: $_isLabelAttached) -> 대기");
      return;
    }

    _isPrinting = true;
    final widgetToPrint = _printQueue.removeAt(0); // 큐에서 첫 번째 라벨 꺼내기

    try {
      await _printerService.printImageLabel(widgetToPrint);

      // 인쇄 완료 직후 바로 ATTACHED 센서가 인식될 수 있도록 약간의 여유를 줌
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      debugPrint("❌ 인쇄 에러: $e");
    } finally {
      _isPrinting = false;
      // 인쇄 명령이 끝났으므로, 센서에서 ATTACHED가 들어오기를 기다립니다.
    }
  }

  Future<void> _loadMockData() async {
    setState(() {
      _isLoading = true;
    });

    List<OrderItem> mockOrders = [];
    int currentSequence = 1001;

    // 주문 카드를 쉽게 생성하기 위한 헬퍼 함수
    OrderItem createOrder(List<String> menus) {
      String rawId = "MOCK_${currentSequence}";
      String? assignedNickname = (Random().nextBool())
          ? TestNameProvider.getNameForId(currentSequence)
          : null;

      OrderItem newOrder = OrderItem(
        orderNo: (currentSequence++).toString(),
        rawOrderId: rawId,
        nickname: assignedNickname,
        items: menus.map((menu) => SubItem(menuName: menu)).toList(),
      );
      /// 시연 - 1002, 1003, 1004, 1005 완료 처리
      //newOrder.drinkCount = menus.length;

      return newOrder;
    }

    // 1. 단일 메뉴 1개씩 (총 3개)
    mockOrders.add(createOrder(["ICED Americano"]));
    mockOrders.add(createOrder(["ICED Cafe Latte"]));
    mockOrders.add(createOrder(["Banana Milk Latte"]));
    mockOrders.add(createOrder(["Espresso"]));

    // 2. 서로 다른 메뉴 조합 2개씩 (총 3개)
    mockOrders.add(createOrder(["ICED Americano", "ICED Cafe Latte"]));
    mockOrders.add(createOrder(["ICED Americano", "Banana Milk Latte"]));
    mockOrders.add(createOrder(["ICED Cafe Latte", "Banana Milk Latte"]));

    // 3. 같은 메뉴 2개씩 (총 3개)
    mockOrders.add(createOrder(["ICED Americano", "ICED Americano"]));
    mockOrders.add(createOrder(["ICED Cafe Latte", "ICED Cafe Latte"]));
    mockOrders.add(createOrder(["Banana Milk Latte", "Banana Milk Latte"]));

    // 4. 3개 모두 포함 (총 1개)
    mockOrders.add(createOrder(["ICED Americano", "ICED Cafe Latte", "Banana Milk Latte"]));

    // 🚀 시연을 위해 생성된 10개의 주문을 무작위로 섞습니다.
    mockOrders.sort((a, b) {
      int orderA = int.tryParse(a.orderNo) ?? 0;
      int orderB = int.tryParse(b.orderNo) ?? 0;
      return orderA.compareTo(orderB);
    });

    /// 시연 - 1002, 1003, 1004, 1005 완료 처리
    // for (var order in mockOrders) {
    //   if (["1002", "1003", "1004", "1005"].contains(order.orderNo)) {
    //     for (var subItem in order.items) {
    //       // 1. KDS UI 강제 완료 처리
    //       subItem.status = OrderStatus.ready;
    //       subItem.progress = 1.0;
    //       subItem.isExtracting = false;
    //       subItem.currentStage = "✅ Demo Ready";
    //
    //       // 2. 서버로 완료 신호 자동 전송 (소켓 연결 시간을 위해 1.5초 지연 후 전송)
    //       int totalCups = order.drinkCount + order.foodCount + order.bottleCount;
    //       if (totalCups <= 0) totalCups = order.items.length; // 안전망
    //
    //       Future.delayed(const Duration(milliseconds: 1500), () {
    //         _socketService.sendOrderReady(order, subItem.menuName, totalCups);
    //         debugPrint("🛠️ [시연 세팅] ${order.orderNo}번(${subItem.menuName}) 자동 완료 신호 전송 완료!");
    //       });
    //     }
    //   }
    // }

    // 약간의 딜레이를 주어 로딩 화면을 보여줌 (선택 사항)
    await Future.delayed(const Duration(milliseconds: 500));

    setState(() {
      _orders = mockOrders;
      _isLoading = false;
    });

    debugPrint("📊 [시연 모드] 10개의 테스트 주문 데이터 로드 및 셔플 완료!");
  }

  void _handleBarcodeScan(String rawData) {
    try {
      String dataToProcess = rawData.trim();
      String orderNo = "";
      String pKey = "";
      int? targetIndex;

      // 🚀 1. 구분자 우측 파싱 방식 (예: Water:20|1001,pkey:1)
      if (dataToProcess.contains("|")) {
        List<String> parts = dataToProcess.split("|");
        String rightPart = parts.length > 1 ? parts[1] : "";

        if (rightPart.isNotEmpty) {
          List<String> rightElements = rightPart.split(",");
          String fullOrderId = rightElements[0]; // "1002.01.02" 형태 수신

          // 🚀 [수정 핵심 3] 주문번호와 인덱스 분리 파싱
          List<String> idParts = fullOrderId.split(".");
          orderNo = idParts[0]; // "1002"
          if (idParts.length >= 2) {
            // "01" -> int 1 -> index 0 (리스트는 0부터 시작하므로)
            targetIndex = (int.tryParse(idParts[1]) ?? 1) - 1;
          }

          for (String el in rightElements) {
            if (el.trim().toLowerCase().startsWith("pkey:")) {
              pKey = el.split(":")[1];
              break;
            }
          }
        }
      }
      // 2. 기존 Base64 JSON 포맷 (안전망)
      else {
        String decodedJsonString = utf8.decode(base64Decode(dataToProcess));
        final Map<String, dynamic> scanData = jsonDecode(decodedJsonString);
        orderNo = scanData['orderNo'];
        pKey = scanData['items'][0]['pKey'].toString();
      }

      debugPrint("🎯 스캔 분석 결과 -> 주문번호: $orderNo, Caye pKey: $pKey");

      // Caye 머신 작동 로직
      if (pKey.isNotEmpty) {
        final order = _orders.firstWhere(
              (o) => o.orderNo == orderNo,
          orElse: () => throw Exception("$orderNo 번 주문을 찾을 수 없습니다."),
        );

        debugPrint("☕ $orderNo번 주문의 pKey($pKey) 제조 준비 중...");

        // 🚀 [수정] 중첩되어 있던 이중 for문을 하나로 합침
        if (targetIndex != null && targetIndex >= 0 && targetIndex < order.items.length) {
          final subItem = order.items[targetIndex];

          // 🛡️ [방어막 작동] 이 바코드가 담당하는 칸이 이미 제조 중이거나 완료되었다면 "무시"
          if (subItem.status == OrderStatus.ready || subItem.isExtracting) {
            debugPrint("🛡️ [중복 방어 작동] 이미 처리 중인 잔입니다. (Order: $orderNo, Seq: ${targetIndex + 1})");
            return;
          }

          // 해당 칸에 대해서만 제조 시작!
          if (pKey.isNotEmpty) {
            _startManufacturing(order, subItem, targetIndex, scannedPKey: pKey);
          }
        } else {
          // (하위 호환성) 만약 테스트용 구형 바코드(순번 없음)를 찍었을 경우 예전처럼 빈 곳을 찾아서 넣음
          for (int i = 0; i < order.items.length; i++) {
            final subItem = order.items[i];

            if (subItem.status == OrderStatus.ready || subItem.isExtracting) continue;

            if (pKey.isNotEmpty) {
              _startManufacturing(order, subItem, i, scannedPKey: pKey);
              break;
            }
          }
        }
      } else {
        debugPrint("⚠️ QR에 Caye(커피) 명령이 포함되어 있지 않습니다.");
      }
    } catch (e) {
      debugPrint("❌ 스캔 데이터 파싱 에러: $e");
    }
  }
  // void _handleBarcodeScan(String rawData) {
  //   try {
  //     String decodedJsonString = utf8.decode(base64Decode(rawData.trim()));
  //
  //     final Map<String, dynamic> scanData = jsonDecode(decodedJsonString);
  //     final String orderNo = scanData['orderNo'];
  //     final List<dynamic> scanItems = scanData['items'];
  //
  //     // 현재 화면 리스트에서 해당 주문번호 찾기
  //     final order = _orders.firstWhere(
  //           (o) => o.orderNo == orderNo,
  //       orElse: () => throw Exception("주문을 찾을 수 없습니다."),
  //     );
  //
  //     debugPrint("🎯 스캔 확인: ${order.orderNo}번 주문 제조 시작");
  //
  //     // QR에 포함된 pKey 리스트를 순회하며 제조 큐에 추가
  //     for (var scanItem in scanItems) {
  //       String pKey = scanItem['pKey'].toString();
  //
  //       // 해당 pKey에 맞는 서브 아이템 찾기 (아메리카노면 pKey 1, 라떼면 2로 매칭)
  //       for (int i = 0; i < order.items.length; i++) {
  //         final subItem = order.items[i];
  //
  //         // 이미 제조 중이거나 완료된 것은 건너뜀
  //         if (subItem.status == OrderStatus.ready || subItem.isExtracting) continue;
  //
  //         // 메뉴명에 따른 pKey 매칭 로직
  //         String itemPKey = "0";
  //         if (subItem.menuName.contains("아메리카노")) itemPKey = "1";
  //         else if (subItem.menuName.contains("라떼")) itemPKey = "2";
  //
  //         if (itemPKey == pKey) {
  //           _startManufacturing(order, subItem, i);
  //           break; // 해당 메뉴 하나를 큐에 넣었으면 다음 scanItem으로
  //         }
  //       }
  //     }
  //   } catch (e) {
  //     debugPrint("❌ 스캔 데이터 파싱 에러: $e");
  //   }
  // }
  bool _isRetrying = false;
  void _updateGlobalExtractionState(ExtractionProgress progress) {
    final data = progress.data;
    if (progress.code == 0x23) {
      int bevStatus = data['beverageStatus'] ?? -1;

      if (bevStatus == 1) {
        // 타이머가 살아있을 때만 실행
        if (_availabilityTimer != null && _availabilityTimer!.isActive) {
          debugPrint("🟢 기기 준비 완료 확인. 2초 대기 후 제조 명령을 전송합니다.");

          _availabilityTimer?.cancel();
          _availabilityTimer = null;

          // 🚀 [추가] UI에 "컵을 놓아주세요" 메시지 표시
          if (_manufacturingQueue.isNotEmpty) {
            setState(() {
              _manufacturingQueue.first.subItem.currentStage = "준비 완료! 컵을 놓아주세요 (2초)";
            });
          }

          // 🚀 [핵심 수정] 2초(2000ms) 지연 후 제조 명령 실행
          Future.delayed(const Duration(seconds: 2), () {
            if (mounted && _manufacturingQueue.isNotEmpty) {
              debugPrint("🚀 2초 경과: 실제 제조 명령(0x20) 발사!");
              _acceptMachinePackets = false;
              _processNextInQueue(); // 여기서 실제 0x20 명령이 나갑니다.
            }
          });
        }
        return;
      } else {
        debugPrint("🔴 기기 아직 바쁨 (상태값: $bevStatus)... 다음 루프 대기");
      }
      return;
    }
    if (progress.code == 0x20) {
      if (data['result'] == 0) {
        // 🚀 [추가] 이미 재시도 타이머가 돌고 있다면 추가 생성 방지
        if (!_isRetrying) {
          _isRetrying = true;
          debugPrint("⚠️ 머신 바쁨 (result: 0) -> 0.5초 후 재시도...");

          Future.delayed(const Duration(milliseconds: 500), () {
            _isRetrying = false; // 타이머 종료 시 해제
            if (mounted && _manufacturingQueue.isNotEmpty) {
              final retryTask = _manufacturingQueue.first;
              _machineService.sendMakeCommand(retryTask.machineIp, retryTask.productKey, retryTask.orderNo);
            }
          });
        }
      } else if (data['result'] == 1) {
        // 수락됨! 본격적인 추출 시작
        debugPrint("✅ 머신 수락 (result: 1) -> 추출 대기...");
        _isRetrying = false; // 성공 시 무조건 해제
        _acceptMachinePackets = true;
        _isWaitingForCleanStart = true;
      }
      return;
    }
    final String? incomingOrderNo = data['orderNo']?.toString();

    // 1. 머신 펌웨어가 업데이트되어 orderNo가 정상적으로 들어오는 경우 (미래를 위한 방어 코드)
    if (incomingOrderNo != null && incomingOrderNo.isNotEmpty) {
      final parts = incomingOrderNo.split('.');
      final String mainOrderNo = parts[0];
      final int subItemIndex = parts.length > 1 ? (int.tryParse(parts[1]) ?? 1) - 1 : 0;

      for (var order in _orders) {
        if (order.orderNo == mainOrderNo) {
          if (subItemIndex >= 0 && subItemIndex < order.items.length) {
            _applyDataToSubItem(order, order.items[subItemIndex], progress);
            if (mounted) setState(() {});
          }
          break;
        }
      }
    }
    // 2. 💡 현재 상황: 머신이 0x24, 0x22 패킷에서 orderNo를 주지 않는 경우 ("" 로 올 때)
    else {
      if (_manufacturingQueue.isEmpty) return;
      if (!_acceptMachinePackets) return; // 🚀 [추가] 방어막이 쳐져 있으면 찌꺼기 패킷 무시!

      if (_isWaitingForCleanStart) {
        if (progress.code == 0x24) {
          final double currentTime = (data['extractTime'] ?? 0).toDouble();
          final double powder = (data['powderWeight'] ?? 0).toDouble();

          // 방금 시작했는데 원두가 1.5g 이상 갈려있거나 1.5초 이상 지났다면 취소된 이전 음료의 찌꺼기!
          if (currentTime > 2.0 || powder > 10.0) {
            debugPrint("🛡️ [방어막 작동] 이전 음료 잔여 데이터 무시 (time: $currentTime, powder: $powder)");
            return; // UI 업데이트 안 하고 바로 버림
          } else {
            // 진짜 0부터 시작하는 새 데이터가 들어오면 방어막 해제
            _isWaitingForCleanStart = false;
          }
        } else if (progress.code == 0x22) {
          final int status = data['status'] ?? 0;
          // 방금 시작했는데 취소(6)나 완료/에러가 오면 무시!
          if (status == 6 || status == 99 || status == 3) {
            debugPrint("🛡️ [방어막 작동] 이전 음료 취소/완료 신호 무시");
            return;
          } else if (status == 1) {
            // 🚀 [핵심 수정] 정상적인 추출 시작 신호(1)가 들어오면 즉시 방어막 해제!
            _isWaitingForCleanStart = false;
            debugPrint("🛡️ [방어막 해제] 정상 추출 시작 신호(1) 수신 완료!");
          }
        }
      }

      // 🚀 [완벽 수정] 화면 리스트를 뒤질 필요 없이, 큐의 첫 번째 녀석에게 바로 데이터 직행!
      final currentTask = _manufacturingQueue.first;
      _applyDataToSubItem(currentTask.order, currentTask.subItem, progress);

      if (mounted) setState(() {});
    }
  }

  void _applyDataToSubItem(OrderItem order, SubItem item, ExtractionProgress progress) {
    final data = progress.data;
    String? newLog;

    if (progress.code == 0x24) { // 실시간 파라미터
      final double currentTime = (data['extractTime'] ?? 0).toDouble();
      final double targetTime = (data['targetExtractTime'] ?? 1).toDouble();
      final double powder = (data['powderWeight'] ?? 0).toDouble();
      final double targetPowder = (data['targetPowderWeight'] ?? 1).toDouble();

      if (currentTime > 0) {
        item.progress = (0.3 + (currentTime / targetTime) * 0.65).clamp(0.0, 0.99);
        item.currentStage = "Extracting Espresso...";
        newLog = "💧 ${data['coffeeWaterQuantity']}ml / 🌡️ ${data['boilerTemp']}°C";
      } else if (powder > 0) {
        item.progress = ((powder / targetPowder) * 0.3).clamp(0.0, 0.3);
        item.currentStage = "Grinding Beans...";
        newLog = "🫘 Grinding beans: $powder g";
      } else {
        // 🚀 [추가] 분쇄도 안 하고 추출도 안 하는데 0x24가 온다면? -> 물/얼음 투출 중!
        item.progress = 0.05; // 0%에 머물지 않게 5%로 고정 (또는 제조사 물방출 키값이 있다면 활용)
        item.currentStage = "Dispensing Water...";
        newLog = "💧 Dispensing Water / Preparing...";
      }
    }
    else if (progress.code == 0x22) { // 상태 보고
      final int status = data['status'] ?? 0;
      item.isExtracting = (status == 1); // 진행 중일 때만 true

      if (status == 3) { // 완료
        _acceptMachinePackets = false;
        item.status = OrderStatus.ready;
        item.progress = 1.0;
        item.isExtracting = false;
        newLog = "✅ Brewing Complete";

        // 서버 동기화 (기존 로직 유지)
        // _socketService.sendOrderReady(order, item.menuName);
        int totalCups = order.drinkCount + order.foodCount + order.bottleCount;
        if (totalCups <= 0) totalCups = order.items.length; // 안전망

        _socketService.sendOrderReady(order, item.menuName, totalCups);
        if (_manufacturingQueue.isNotEmpty) {
          _manufacturingQueue.removeAt(0); // 첫 번째 항목 제거
          _queueNotifier.value++;
          if (_manufacturingQueue.isNotEmpty) {
            _availabilityTimer?.cancel();
            _availabilityTimer = Timer.periodic(const Duration(milliseconds: 1000), (timer) {
              _checkNextTaskAvailability();
            });
            _checkNextTaskAvailability(); // 즉시 1회 실행
          } else {
            _isMachineBusy = false;
          }
        } else {
          _isMachineBusy = false; // 더 이상 대기열이 없으면 머신 휴식
        }
      } else if (status == 99 || status == 6) { // 에러
        _acceptMachinePackets = false;
        item.isError = true;
        item.isExtracting = false; // 에러 시 게이지 클릭은 가능하게 유지
        final dynamic errorData = data['errorCode'];
        item.errorCode = (errorData is List && errorData.isNotEmpty) ? errorData.join(", ") : errorData?.toString();
        newLog = "❌ Error Occurred: ${item.errorCode}";
        // 🚀 [추가됨] 에러 발생 시 큐가 멈추지 않도록 에러 난 것을 빼고 다음 작업 실행
        if (_manufacturingQueue.isNotEmpty) {
          _manufacturingQueue.removeAt(0);
          _queueNotifier.value++;

          if (_manufacturingQueue.isNotEmpty) {
            _availabilityTimer?.cancel();
            _availabilityTimer = Timer.periodic(const Duration(milliseconds: 1000), (timer) {
              _checkNextTaskAvailability();
            });
            _checkNextTaskAvailability();
          } else {
            _isMachineBusy = false;
          }
        } else {
          _isMachineBusy = false;
        }
      }
    }

    // 로그 누적 (다이얼로그 열었을 때 과거 로그가 보이게 함)
    if (newLog != null && (item.logs.isEmpty || item.logs.first != newLog)) {
      item.logs.insert(0, newLog);
    }
  }

  Timer? _usbKeepAliveTimer;
  void _startUsbHeartbeat() {
    _usbKeepAliveTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        List<UsbDevice> devices = await UsbSerial.listDevices();

        if (devices.isNotEmpty) {
          // 🚀 포트 생성을 시도합니다. (이때 권한이 없으면 시스템 팝업을 준비합니다.)
          UsbPort? port = await devices[0].create();

          if (port != null) {
            // 🚀 포트를 여는 순간, 권한이 없다면 안드로이드 OS가 "허용하시겠습니까?" 팝업을 띄웁니다.
            bool openResult = await port.open();

            if (openResult) {
              debugPrint("💓 [USB Heartbeat] Port Poked & Opened (Keep Awake)");
              // 하트비트 목적이므로 열었다가 바로 닫습니다.
              await port.close();
            } else {
              debugPrint("⚠️ [USB Heartbeat] Failed to open port (Wait for permission)");
            }
          }
        }
        debugPrint("🔍 [USB Heartbeat] Found: ${devices.length}");
      } catch (e) {
        // 권한 거부 시 여기서 SecurityException이 잡히지만,
        // 앱이 계속 시도하면 결국 사용자가 허용할 수 있는 기회를 줍니다.
        debugPrint("❌ [USB Heartbeat] Error/Pending: $e");
      }
    });
  }

  Future<void> _loadCsvData() async {
    try {
      final String rawData =
          await rootBundle.loadString("assets/data/orders.csv");
      final normalizedData =
          rawData.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

      // 구분자는 쉼표(,), 줄바꿈은 \n으로 명시해줍니다.
      List<List<dynamic>> csvTable = const CsvToListConverter(
        fieldDelimiter: ',',
        eol: '\n',
        shouldParseNumbers: false, // 숫자 파싱 에러 방지를 위해 false 추천
      ).convert(normalizedData);

      debugPrint("📊 [결과] 파싱된 행 개수: ${csvTable.length}");

      Map<String, OrderItem> groupMap = {};
      int currentSequence = 1001;
      final random = Random();
      for (var i = 1; i < csvTable.length; i++) {
        final row = csvTable[i];
        if (row.length < 7) continue;

        String rawId = row[0].toString(); // 원본 긴 ID
        String menuName = row[6].toString();
        int type = int.tryParse(row[7].toString()) ?? 0;

        if (!groupMap.containsKey(rawId)) {
          String? assignedNickname = (Random().nextBool())
              ? TestNameProvider.getNameForId(currentSequence)
              : null;
          groupMap[rawId] = OrderItem(
            orderNo: (currentSequence++).toString(),
            rawOrderId: rawId,
            nickname: assignedNickname,
            items: [],
          );
        }

        if (type == 1) {
          groupMap[rawId]!.drinkCount++;
        } else if (type == 2) {
          groupMap[rawId]!.foodCount++;
        } else if (type == 3) {
          groupMap[rawId]!.bottleCount++;
        }
        // 해당 그룹에 서브 아이템 추가
        groupMap[rawId]!.items.add(SubItem(menuName: menuName));
      }

      setState(() {
        _orders = groupMap.values.toList();
      });
    } catch (e) {
      debugPrint("❌ CSV 에러: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // // 3. [제조 완료] 버튼 클릭 시 실행될 함수
  // void _onCompleteCooking(OrderItem order) {
  //   setState(() {
  //     order.status = OrderStatus.ready; // 화면 상태를 '준비됨'으로 변경
  //   });
  //
  //   // 🚀 소켓을 통해 서버로 "READY:주문번호" 신호 전송
  //   _socketService.sendOrderReady(order.orderNo, order.menuName);
  //
  //   ScaffoldMessenger.of(context).showSnackBar(
  //     SnackBar(content: Text("${order.orderNo}번 제조 완료 신호를 보냈습니다.")),
  //   );
  // }
  //
  // // 4. [픽업 완료] 버튼 클릭 시 실행될 함수
  // void _onCompletePickup(OrderItem order) {
  //   setState(() {
  //     _orders.remove(order);
  //     order.status = OrderStatus.pending;
  //     _orders.add(order); // 리스트 맨 뒤로 보냄
  //   });
  // }

  final TextEditingController _heightController = TextEditingController(text: "1000"); // 기본값 1000

  void _onStartCalibration(double height) {
    _socketService.sendStartCalibration(height);
    setState(() {
      _isCalibOverlayVisible = true;
    });
  }
  final List<String> testMenus = [
    "아이스 아메리카노", "카페 라떼", "바닐라 빈 라떼", "자몽 에이드", "딸기 스무디",
    "블루베리 머핀", "초코칩 쿠키", "치즈 케이크", "에스프레소", "콜드브루"
  ];

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      // 🚀 1. 디버그용: 스캐너가 보내는 '모든' 키 신호를 로그캣에 강제로 찍습니다.
      // (만약 스캔했는데 이 로그조차 안 올라오면 스캐너 연결이나 앱 포커스 문제입니다)
      debugPrint("⌨️ [스캐너 감지] Key: ${event.logicalKey.keyLabel}, Char: ${event.character}");

      // 🚀 2. 스캐너 종류에 따라 Enter 신호가 다를 수 있으므로 방어 코드 추가
      bool isEnterKey = (event.logicalKey == LogicalKeyboardKey.enter) ||
          (event.logicalKey == LogicalKeyboardKey.numpadEnter) ||
          (event.character == '\n') ||
          (event.character == '\r');

      if (isEnterKey) {
        if (_scanBuffer.isNotEmpty) {
          debugPrint("🎯 [최종 버퍼 완성] 스캐너 입력 완료: $_scanBuffer");
          _handleBarcodeScan(_scanBuffer); // 완성된 문자열을 파싱 함수로 넘김
          _scanBuffer = ""; // 다음 스캔을 위해 버퍼 초기화
        }
      }
      // 특수기호나 일반 문자열일 경우 버퍼에 차곡차곡 쌓음
      else if (event.character != null) {
        _scanBuffer += event.character!;
      }
    }
    // 앱의 다른 버튼 클릭 등을 막지 않도록 false 반환
    return false;
  }
  // bool _handleKeyEvent(KeyEvent event) {
  //   // 키가 눌렸을 때만 반응합니다 (KeyDownEvent)
  //   if (event is KeyDownEvent) {
  //     // 1. 스캐너가 입력을 마치고 '엔터'를 쳤을 때
  //     if (event.logicalKey == LogicalKeyboardKey.enter) {
  //       if (_scanBuffer.isNotEmpty) {
  //         debugPrint("🎯 [Hardware] 스캐너 입력 완료: $_scanBuffer");
  //         _handleBarcodeScan(_scanBuffer); // 기존 바코드 처리 함수로 전달!
  //         _scanBuffer = ""; // 버퍼를 비워주어 다음 스캔을 준비합니다.
  //       }
  //     }
  //     // 2. 일반 문자나 숫자가 들어올 때
  //     else if (event.character != null) {
  //       _scanBuffer += event.character!; // 버퍼에 글자를 하나씩 이어 붙입니다.
  //     }
  //   }
  //   // false를 반환해야 앱의 다른 기능(버튼 클릭 등)이 막히지 않습니다.
  //   return false;
  // }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _extractionSub?.cancel();
    // _hiddenInputController.dispose();
    // _hiddenFocusNode.dispose();
    _usbKeepAliveTimer?.cancel();
    _heightController.dispose();
    _socketService.dispose(); // 앱 종료 시 소켓 닫기
    _pageController.dispose();
    _printerService.dispose();
    _machineService.dispose();
    _availabilityTimer?.cancel();
    super.dispose();
  }



  @override
  Widget build(BuildContext context) {
    if (_isLoading)
      return Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: CircularProgressIndicator()));
    // 페이지당 9개씩 계산
    Size screenSize = MediaQuery.of(context).size;
    Orientation orientation = MediaQuery.of(context).orientation;

    // 2. 가로 개수(Columns) 결정 (기존 로직 유지)
    int crossAxisCount;
    if (screenSize.width < 600) crossAxisCount = 1;
    else if (screenSize.width < 1000) crossAxisCount = 2;
    else if (screenSize.width < 1400) crossAxisCount = 3;
    else crossAxisCount = 4;

    // 3. 세로 줄 수(Rows) 결정 ★ 핵심 추가 포인트
    int rowCount;
    double minCardHeight = 320.0;
    if (orientation == Orientation.portrait) {
      rowCount = 3; // 세로 모드에선 무조건 3줄 유지
    } else {
      // 가로 모드일 때: 화면 전체 높이를 '최소 카드 높이'로 나누어 몇 줄을 넣을지 계산
      rowCount = (screenSize.height / minCardHeight).floor();

      // 방어 코드: 최소 1줄, 최대 3줄로 제한
      if (rowCount < 1) rowCount = 1;
      if (rowCount > 3) rowCount = 3;
    }

    // 4. 페이지당 아이템 개수 재계산
    int itemsPerPage = crossAxisCount * rowCount;
    int pageCount = _orders.isEmpty ? 1 : (_orders.length / itemsPerPage).ceil();
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("KDS", style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(width: 12),
            // 🚀 실시간 상태 표시등 (ValueListenableBuilder 사용)
            ValueListenableBuilder<bool>(
              valueListenable: _socketService.isConnectedNotifier,
              builder: (context, isConnected, child) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: isConnected ? Colors.green.withOpacity(0.1) : Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: isConnected ? Colors.green : Colors.red, width: 1.5),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(radius: 4, backgroundColor: isConnected ? Colors.green : Colors.red),
                      const SizedBox(width: 6),
                      Text(
                        isConnected ? "ONLINE" : "OFFLINE",
                        style: TextStyle(
                          fontSize: 12,
                          color: isConnected ? Colors.green : Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const CayeManagementScreen(machineIp: "192.168.10.193"),
                  ),
                );
              },
              label: const Text("Machine Control", style: TextStyle(fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.greenAccent, width: 1.5),
                foregroundColor: Colors.greenAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),

          // Padding(
          //   padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          //   child: OutlinedButton(
          //     onPressed: () => _printerService.printTest(testMenus),
          //     style: OutlinedButton.styleFrom(
          //       side: const BorderSide(color: Colors.cyanAccent, width: 1.5),
          //       foregroundColor: Colors.cyanAccent,
          //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          //     ),
          //     child: const Text("텍스트출력", style: TextStyle(fontWeight: FontWeight.bold)),
          //   ),
          // ),
          // Padding(
          //   padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          //   child: OutlinedButton.icon(
          //     onPressed: () => _showNudofControlDialog(context),
          //     icon: const Icon(Icons.settings_input_component, size: 18),
          //     label: const Text("Nudof", style: TextStyle(fontWeight: FontWeight.bold)),
          //     style: OutlinedButton.styleFrom(
          //       side: const BorderSide(color: Colors.yellowAccent, width: 1.5),
          //       foregroundColor: Colors.yellowAccent,
          //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          //     ),
          //   ),
          // ),

          // Padding(
          //   padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          //   child: OutlinedButton(
          //     onPressed: () {
          //       // 🚀 제조사 규격에 맞춘 테스트용 QR 데이터
          //       // 포맷: 원료명:용량,원료명:용량|주문번호
          //       //String testQrData = "Cold_Brew:50,Water:120|1001.01";
          //       String testQrData = "Red:50|1001.01,pkey:2";
          //
          //       _printerService.printImageLabel(
          //         OrderCardWidget(
          //           orderNo: "1004", // 카드에 보일 임시 주문번호
          //           menus: const ["Test Beverage"], // 카드에 보일 임시 메뉴명
          //           qrData: testQrData, // 👈 실제 QR코드에 들어갈 텍스트!
          //         ),
          //       );
          //
          //       ScaffoldMessenger.of(context).showSnackBar(
          //         const SnackBar(content: Text("테스트용 QR 라벨 인쇄 중...")),
          //       );
          //     },
          //     style: OutlinedButton.styleFrom(
          //       side: const BorderSide(color: Colors.cyanAccent, width: 1.5),
          //       foregroundColor: Colors.cyanAccent,
          //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          //     ),
          //     child: const Text("콜드브루", style: TextStyle(fontWeight: FontWeight.bold)),
          //   ),
          // ),
          // Padding(
          //   padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          //   child: OutlinedButton(
          //     onPressed: () {
          //       // 🚀 제조사 규격에 맞춘 테스트용 QR 데이터
          //       // 포맷: 원료명:용량,원료명:용량|주문번호
          //       String testQrData = "Banana_Syrup:20|1001.01";
          //
          //       _printerService.printImageLabel(
          //         OrderCardWidget(
          //           orderNo: "1001", // 카드에 보일 임시 주문번호
          //           menus: const ["바나나 시럽 테스트"], // 카드에 보일 임시 메뉴명
          //           qrData: testQrData, // 👈 실제 QR코드에 들어갈 텍스트!
          //         ),
          //       );
          //
          //       ScaffoldMessenger.of(context).showSnackBar(
          //         const SnackBar(content: Text("테스트용 QR 라벨 인쇄 중...")),
          //       );
          //     },
          //     style: OutlinedButton.styleFrom(
          //       side: const BorderSide(color: Colors.cyanAccent, width: 1.5),
          //       foregroundColor: Colors.cyanAccent,
          //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          //     ),
          //     child: const Text("바나나", style: TextStyle(fontWeight: FontWeight.bold)),
          //   ),
          // ),
          // Padding(
          //   padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          //   child: OutlinedButton(
          //     onPressed: () {
          //       // 🚀 [수정] 디스펜서 우회 테스트용 QR 데이터
          //       String testQrData = "Banana_Syrup:20|1004,pkey:21";
          //
          //       _printerService.printImageLabel(
          //         OrderCardWidget(
          //           orderNo: "1001",
          //           menus: const ["Banana milk latte"],
          //           qrData: testQrData,
          //         ),
          //       );
          //
          //       ScaffoldMessenger.of(context).showSnackBar(
          //         const SnackBar(content: Text("우회 테스트용 QR 라벨 인쇄 중...")),
          //       );
          //     },
          //     style: OutlinedButton.styleFrom(
          //       side: const BorderSide(color: Colors.cyanAccent, width: 1.5),
          //       foregroundColor: Colors.cyanAccent,
          //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          //     ),
          //     child: const Text("테스트출력", style: TextStyle(fontWeight: FontWeight.bold)),
          //   ),
          // ),
          // Padding(
          //   padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          //   child: OutlinedButton(
          //     onPressed: () => _showCalibrationConfirmDialog(context),
          //     style: OutlinedButton.styleFrom(
          //       side: const BorderSide(color: Colors.orangeAccent, width: 1.5),
          //       foregroundColor: Colors.orangeAccent,
          //       shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          //       padding: const EdgeInsets.symmetric(horizontal: 16),
          //     ),
          //     child: const Text(
          //       "정밀보정",
          //       style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          //     ),
          //   ),
          // ),
        ],
        backgroundColor: Colors.blueGrey[900],
        centerTitle: true,
      ),
      body: Stack(
            children: [
              // Offstage(
              //   offstage: true, // 화면에서 아예 안 보이게 숨김
              //   child: TextField(
              //     controller: _hiddenInputController,
              //     focusNode: _hiddenFocusNode,
              //     autofocus: true,
              //     keyboardType: TextInputType.none, // 가상 키보드 절대 띄우지 마!
              //     autocorrect: false,               // 오타 자동 수정 끄기
              //     enableSuggestions: false,         // 단어 추천(중국어 병음 등) 끄기
              //     obscureText: true,
              //     onChanged: (text) {
              //       debugPrint("✍️ [CCTV] 타자 치는 중... 현재 내용: $text");
              //     },
              //     onSubmitted: (value) {
              //       // 스캐너가 엔터를 치면 이 onSubmitted가 실행됩니다!
              //       debugPrint("🎯 스캐너 입력 완료: $value");
              //       if (value.isNotEmpty) {
              //         _handleBarcodeScan(value); // Base64 파싱 함수로 전달
              //         _hiddenInputController.clear(); // 처리 후 창 비우기
              //       }
              //       _hiddenFocusNode.requestFocus(); // 다시 포커스 잡기
              //     },
              //   ),
              // ),
              _orders.isEmpty
                  ? const Center(child: Text("No orders in queue.", style: TextStyle(color: Colors.white)))
                  : Column(
                children: [
                  Expanded(
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: pageCount,
                      onPageChanged: (int page) => setState(() => _currentPage = page),
                      itemBuilder: (context, pageIndex) {
                        int start = pageIndex * itemsPerPage;
                        int end = (start + itemsPerPage < _orders.length) ? start + itemsPerPage : _orders.length;
                        final pageOrders = _orders.sublist(start, end);
                        return LayoutBuilder(
                          builder: (context, constraints) {
                            double totalSpacing = (rowCount + 1) * 12.0;
                            final double dynamicHeight = (constraints.maxHeight - totalSpacing) / rowCount;
                            return Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: GridView.builder(
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: crossAxisCount,
                                  mainAxisExtent: dynamicHeight,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                ),
                                itemCount: pageOrders.length,
                                itemBuilder: (context, index) => _buildOrderCard(pageOrders[index]),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20.0),
                    child: Text("${_currentPage + 1} / $pageCount",
                        style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),

              // [레이어 2] 중간: 리모컨 (미세 조정 시에만 표시)
              // if (_isRemoteVisible)
              //   Positioned.fill(child: _buildRemoteController()),

              // [레이어 3] 최상단: 차단막 (9점 보정 및 검증 화면일 때 모든 것을 덮음)
              if (_isCalibOverlayVisible)
                Container(
                  width: double.infinity,
                  height: double.infinity,
                  color: Colors.black.withOpacity(0.9),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.orangeAccent, strokeWidth: 6),
                        const SizedBox(height: 30),
                        const Text("Calibration in Progress...",
                            style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 10),
                        const Text("Please follow the instructions on the Pickup Table.",
                            style: TextStyle(color: Colors.white54, fontSize: 18)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showQueueDialog(),
        backgroundColor: _manufacturingQueue.isEmpty ? Colors.blueGrey[800] : Colors.orange[800],
        icon: Icon(
            Icons.format_list_numbered,
            color: _manufacturingQueue.isEmpty ? Colors.white54 : Colors.white
        ),
        label: Text(
          _manufacturingQueue.isEmpty
              ? "Queue Empty"
              : "${_manufacturingQueue.length} in Queue",
          style: TextStyle(
              color: _manufacturingQueue.isEmpty ? Colors.white54 : Colors.white,
              fontWeight: FontWeight.bold
          ),
        ),
      ),
    );
  }

  void _showQueueDialog() {
    showDialog(
      context: context,
      builder: (context) {
        // 다이얼로그가 떠 있는 동안에도 큐가 변경되면 반영되도록 StatefulBuilder 사용
        return ValueListenableBuilder<int>(
            valueListenable: _queueNotifier,
            builder: (context, value, child){
              return AlertDialog(
                backgroundColor: Colors.grey[900],
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                title: const Row(
                  children: [
                    Icon(Icons.list_alt, color: Colors.orangeAccent),
                    SizedBox(width: 10),
                    Text("Brewing Queue", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ],
                ),
                content: SizedBox(
                  width: 350,
                  height: 300, // 스크롤 가능하도록 높이 고정
                  child: _manufacturingQueue.isEmpty
                      ? const Center(child: Text("No brewing commands in queue.", style: TextStyle(color: Colors.white54)))
                      : ListView.builder(
                    itemCount: _manufacturingQueue.length,
                    itemBuilder: (context, index) {
                      final item = _manufacturingQueue[index];
                      final bool isExtracting = (index == 0); // 첫 번째 항목은 항상 제조 중

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isExtracting ? Colors.orangeAccent.withOpacity(0.2) : Colors.white10,
                          child: Text("${index + 1}",
                              style: TextStyle(color: isExtracting ? Colors.orangeAccent : Colors.white54)),
                        ),
                        title: Text(item.subItem.menuName,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        subtitle: Text("Order No: ${item.orderNo}", style: const TextStyle(color: Colors.white54)),
                        trailing: isExtracting
                            ? const Text("Brewing...", style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold))
                            : const Text("Pending", style: TextStyle(color: Colors.white30)),
                      );
                    },
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("Close", style: TextStyle(color: Colors.white)),
                  ),
                ],
              );
            }
        );
      },
    );
  }

// 공통 버튼 위젯
  Widget _buildAdminButton(String label, IconData icon, Color color, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label),
        style: ElevatedButton.styleFrom(backgroundColor: color.withOpacity(0.8)),
      ),
    );
  }

  void _showCalibrationConfirmDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false, // 실수로 창을 닫는 것 방지
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.straighten, color: Colors.orangeAccent),
            SizedBox(width: 10),
            Text("Enter Installation Height", style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Please enter the current sensor height (mm).\nThis is required for accurate calibration.",
              style: TextStyle(color: Colors.white70, height: 1.5, fontSize: 14),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _heightController,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                labelText: "Installation Height (mm)",
                labelStyle: const TextStyle(color: Colors.orangeAccent),
                enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.orangeAccent)),
                suffixText: "mm",
                suffixStyle: const TextStyle(color: Colors.white54),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange[800],
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              // 입력값 검증 및 변환
              double? inputHeight = double.tryParse(_heightController.text);
              if (inputHeight == null || inputHeight <= 0) {
                // 잘못된 입력 시 기본값 혹은 경고 (여기서는 1000으로 방어)
                inputHeight = 1000.0;
              }

              _onStartCalibration(inputHeight); // 입력된 높이와 함께 시작
              Navigator.pop(context);

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Height set to ${inputHeight.toInt()}mm. Starting calibration...")),
              );
            },
            child: const Text("Start Calibration"),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderCard(OrderItem order) {
    // 모든 메뉴가 완료되었을 때만 배경색을 변경함
    bool isFullReady = order.isAllReady;

    return Container(
      decoration: BoxDecoration(
        color: isFullReady ? Colors.indigo[900] : Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isFullReady ? Colors.blueAccent : Colors.white10, width: 2),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("NO. ${order.orderNo}", style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
                    // if (order.nickname != null)
                    //   Container(
                    //     margin: const EdgeInsets.only(top: 4), // 약간의 여백 추가
                    //     padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    //     decoration: BoxDecoration(color: Colors.orangeAccent, borderRadius: BorderRadius.circular(4)),
                    //     child: Text(order.nickname!,
                    //         style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14)),
                    //   ),
                  ],
                ),
              ),

              // 🚀 [추가 사항] 개별 라벨 출력 버튼
              // IconButton(
              //   icon: const Icon(Icons.print, color: Colors.cyanAccent, size: 32),
              //   padding: EdgeInsets.zero,
              //   constraints: const BoxConstraints(),
              //   onPressed: () {
              //     // 1. QR에 심을 JSON 데이터 조립 (주문번호 + 메뉴별 pKey)
              //     List<Map<String, dynamic>> qrItems = order.items.map((subItem) {
              //       String pKey = "0"; // 기본값
              //       if (subItem.menuName.contains("아메리카노")) pKey = "1";
              //       else if (subItem.menuName.contains("라떼")) pKey = "2";
              //
              //       return {
              //         "pKey": pKey
              //       };
              //     }).toList();
              //
              //     String rawJson = jsonEncode({
              //       "orderNo": order.orderNo,
              //       "items": qrItems
              //     });
              //     String qrPayload = base64Encode(utf8.encode(rawJson));
              //
              //     // 2. 프린터로 전송
              //     _printerService.printImageLabel(
              //         OrderCardWidget(
              //           orderNo: order.orderNo,
              //           menus: order.items.map((e) => e.menuName).toList(),
              //           qrData: qrPayload, // 이제 영문+숫자 덩어리가 들어갑니다!
              //         )
              //     );
              //
              //     // 3. 사용자 알림 피드백
              //     ScaffoldMessenger.of(context).showSnackBar(
              //       SnackBar(
              //           content: Text("${order.orderNo}번 라벨 인쇄 명령 전송!"),
              //           duration: const Duration(seconds: 1)
              //       ),
              //     );
              //     //_hiddenFocusNode.requestFocus();
              //   },
              // ),
              IconButton(
                icon: const Icon(Icons.print, color: Colors.cyanAccent, size: 32),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  final items = order.items;
                  int totalItems = items.length;

                  // 1. 주문에 포함된 메뉴 개수만큼 순회하며 개별 라벨 생성
                  for (int i = 0; i < totalItems; i++) {
                    final menuName = items[i].menuName;

                    // 기본값
                    String dispenserData = "N:0";
                    String pKey = "0";

                    // 🚀 2. 대표님 요청 규격에 맞춘 분기 처리
                    if (menuName.contains("Americano")) {
                      dispenserData = "N:0";
                      pKey = "16";
                    } else if (menuName.contains("Cafe Latte")) {
                      dispenserData = "N:0";
                      pKey = "21";
                    } else if (menuName.contains("Banana Milk Latte")) {
                      dispenserData = "Banana_Syrup:20";
                      pKey = "21";
                    } else if (menuName.contains("Espresso")) {
                      dispenserData = "N:0";
                      pKey = "1";
                    }

                    //// 3. 최종 QR 데이터 문자열 (예: N:0|1004,pkey:16)
                    //String qrPayload = "$dispenserData|${order.orderNo},pkey:$pKey";

                    // 서브 시퀀스 생성 (예: 1/2, 2/2)
                    String seq = (i + 1).toString().padLeft(2, '0');
                    String totSeq = totalItems.toString().padLeft(2, '0');

                    String uniqueOrderId = "${order.orderNo}.$seq.$totSeq";

                    String qrPayload = "$dispenserData|$uniqueOrderId,pkey:$pKey";

                    // 4. 대기열에 추가
                    _printQueue.add(
                        OrderCardWidget(
                          orderNo: order.orderNo,
                          sequence: seq,
                          totalSequence: totSeq,
                          menus: [menuName], // 👈 해당 라벨은 이 메뉴 하나만 표시!
                          qrData: qrPayload,
                        )
                    );
                  }

                  // 5. 알림 및 대기열 처리 시작
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text("$totalItems labels for Order ${order.orderNo} added to print queue!"),
                        duration: const Duration(seconds: 2)
                    ),
                  );

                  _processPrintQueue(); // 대기열 처리 발동!
                },
              ),
            ],
          ),
          const Divider(color: Colors.white24, height: 15),

          // 1. 메뉴 리스트 영역 (스크롤 가능)
          Expanded(
            child: ListView.builder(
              itemCount: order.items.length,
              itemBuilder: (context, index) {
                final subItem = order.items[index];
                bool isSubReady = subItem.status == OrderStatus.ready;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Column( // Row에서 Column으로 변경 (이름 아래에 게이지)
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(subItem.menuName,
                                style: TextStyle(
                                    color: isSubReady ? Colors.white38 : Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500)),
                          ),
                          // if (!isSubReady)
                          //   IconButton(
                          //     constraints: const BoxConstraints(),
                          //     padding: const EdgeInsets.symmetric(horizontal: 8),
                          //     icon: const Icon(Icons.fast_forward, color: Colors.purpleAccent, size: 24),
                          //     onPressed: () {
                          //       setState(() {
                          //         // 1. UI 상태를 즉시 완료로 변경
                          //         subItem.status = OrderStatus.ready;
                          //         subItem.progress = 1.0;
                          //         subItem.isExtracting = false;
                          //         subItem.currentStage = "✅ (Test) Complete";
                          //
                          //         // 2. 만약 실수로 제조 버튼을 누른 상태였다면 큐에서 제거 (큐 꼬임 방지)
                          //         _manufacturingQueue.removeWhere((q) => q.subItem == subItem);
                          //         _queueNotifier.value = _manufacturingQueue.length;
                          //       });
                          //
                          //       // 3. 서버(픽업 테이블)로 ORDER_READY 신호 발사!
                          //       // _socketService.sendOrderReady(order, subItem.menuName);
                          //       int totalCups = order.drinkCount + order.foodCount + order.bottleCount;
                          //       if (totalCups <= 0) totalCups = order.items.length; // 안전망
                          //
                          //       _socketService.sendOrderReady(order, subItem.menuName, totalCups);
                          //
                          //       ScaffoldMessenger.of(context).showSnackBar(
                          //         SnackBar(
                          //           content: Text("🛠️ 테스트 완료 신호 전송: ${subItem.menuName}"),
                          //           duration: const Duration(seconds: 1),
                          //         ),
                          //       );
                          //     },
                          //   ),
                          // 완료 아이콘 표시
                          if (isSubReady)
                            const Icon(Icons.check_circle, color: Colors.greenAccent, size: 24)
                          else if (!subItem.isExtracting && !subItem.isError)
                            IconButton(
                              constraints: const BoxConstraints(),
                              padding: EdgeInsets.zero,
                              icon: const Icon(Icons.play_circle_fill, color: Colors.orangeAccent, size: 30),
                              onPressed: () => _startManufacturing(order, subItem, index),
                            ),
                        ],
                      ),

                      // 🚀 [수정 사항 1] 진행 중일 때 일자형(Linear) 게이지바 표시
                      if (subItem.isExtracting || subItem.isError)
                        GestureDetector(
                          onTap: () {
                            String pKey = "16"; // 기본값
                            if (subItem.menuName.contains("Americano")) pKey = "16";
                            else if (subItem.menuName.contains("Cafe Latte")) pKey = "21";
                            else if (subItem.menuName.contains("Banana Milk Latte")) pKey = "21";
                            else if (subItem.menuName.contains("Espresso")) pKey = "1";

                            String combinedOrderNo = "${order.orderNo}.${(index + 1).toString().padLeft(2, '0')}";

                            showExtractionMonitor(
                              context, _machineService, subItem.menuName,
                              machineIp: "192.168.10.193",
                              productKey: pKey,             // 👈 1, 2가 아닌 실제 pKey (16, 21) 전달!
                              orderNo: combinedOrderNo,     // 👈 단순 1001이 아닌 1001.01 형태의 실제 제조 번호 전달!
                              subItem: subItem,
                              onCancel: () => _handleItemCancelled(subItem),
                            );
                          },
                          child: Container(
                            margin: const EdgeInsets.only(top: 8),
                            child: Column(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: subItem.progress,
                                    minHeight: 10, // 게이지 두께
                                    backgroundColor: Colors.white10,
                                    color: subItem.isError ? Colors.redAccent : Colors.orangeAccent,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(subItem.currentStage, style: TextStyle(fontSize: 10, color: subItem.isError ? Colors.redAccent : Colors.orangeAccent)),
                                    Text("${(subItem.progress * 100).toInt()}%", style: const TextStyle(fontSize: 10, color: Colors.white70)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 10),

          // 2. 카드 하단 픽업 완료 버튼 (전체 완료 시에만 활성화)
          ElevatedButton(
            onPressed: !isFullReady ? null : () {
              setState(() {
                _orders.remove(order); // 리스트에서 제거
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red[900],
              minimumSize: const Size(double.infinity, 50),
            ),
            child: const Text("Done", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _startManufacturing(OrderItem order, SubItem subItem, int index, {String? scannedPKey}) {
    const String machineIp = "192.168.10.193";
    String? finalPKey = scannedPKey;

    if (finalPKey == null || finalPKey.isEmpty) {
      if (subItem.menuName.contains("Americano")) finalPKey = "16";
      else if (subItem.menuName.contains("Cafe Latte")) finalPKey = "21";
      else if (subItem.menuName.contains("Banana Milk Latte")) finalPKey = "21";
      else if (subItem.menuName.contains("Espresso")) finalPKey = "1";
    }

    if (finalPKey != null) {
      String combinedOrderNo = "${order.orderNo}.${(index + 1).toString().padLeft(2, '0')}";

      // 1. 큐 아이템 생성
      final newItem = ManufacturingQueueItem(
        machineIp: machineIp,
        productKey: finalPKey, // 👈 여기에 21이 들어갑니다!
        orderNo: combinedOrderNo,
        subItem: subItem,
        order: order,
      );

      setState(() {
        subItem.progress = 0.0;
        subItem.isError = false;
        subItem.errorCode = null;
        subItem.status = OrderStatus.pending;

        _manufacturingQueue.add(newItem);
        subItem.logs = ["⏳ Added to brewing queue... (pKey: $finalPKey)"];
        subItem.currentStage = "Pending";
        subItem.isExtracting = true;
        _queueNotifier.value++;
      });

      // 3. 머신이 쉬고 있다면 바로 첫 번째 작업 시작
      if (!_isMachineBusy) {
        _isMachineBusy = true;

        _availabilityTimer?.cancel();
        _availabilityTimer = Timer.periodic(const Duration(milliseconds: 1000), (timer) {
          _checkNextTaskAvailability();
        });
        _checkNextTaskAvailability();
      }
    }
  }

  List<ManufacturingQueueItem> _manufacturingQueue = [];
  bool _isMachineBusy = false; // 현재 머신이 제조 중인지 여부
  bool _acceptMachinePackets = false;
  bool _isWaitingForCleanStart = false;

  final ValueNotifier<int> _queueNotifier = ValueNotifier<int>(0);
  Timer? _availabilityTimer;
// 🚀 큐의 첫 번째 항목을 실제로 머신에 전송하는 함수
  void _processNextInQueue() {
    if (_manufacturingQueue.isEmpty) {
      _isMachineBusy = false;
      return;
    }

    _isMachineBusy = true;
    final nextTask = _manufacturingQueue.first;

    setState(() {
      _acceptMachinePackets = false;
      nextTask.subItem.isExtracting = true; // 게이지 바 활성화
      nextTask.subItem.logs.insert(0, "🚀 Brewing command sent (${nextTask.orderNo})");
    });

    // 머신에 실제 명령 전송
    _machineService.sendMakeCommand(nextTask.machineIp, nextTask.productKey, nextTask.orderNo);
  }

  void _checkNextTaskAvailability() {
    if (_manufacturingQueue.isEmpty) {
      _availabilityTimer?.cancel();
      _isMachineBusy = false;
      return;
    }

    final nextTask = _manufacturingQueue.first;

    // UI에 '확인 중' 표시
    setState(() {
      nextTask.subItem.isExtracting = true;
      nextTask.subItem.currentStage = "Checking machine status...";
    });

    // 0x23 발사!
    _machineService.sendCheckAvailability(nextTask.machineIp, nextTask.productKey);
  }

  void _handleItemCancelled(SubItem cancelledItem) {
    if (!mounted) return;

    setState(() {
      // 1. 큐에서 해당 아이템이 어디 있는지 찾기
      int queueIndex = _manufacturingQueue.indexWhere((q) => q.subItem == cancelledItem);

      if (queueIndex != -1) {
        // 2. 큐에서 완전히 삭제
        _manufacturingQueue.removeAt(queueIndex);
        _queueNotifier.value = _manufacturingQueue.length;

        // 3. 만약 취소한 녀석이 '현재 제조 중(1번 타자)' 이었다면? 다음 녀석으로 넘겨야 함!
        if (queueIndex == 0) {
          _acceptMachinePackets = false; // 취소된 기기에서 늦게 오는 찌꺼기 패킷 무시

          if (_manufacturingQueue.isNotEmpty) {
            _availabilityTimer?.cancel();
            _availabilityTimer = Timer.periodic(const Duration(milliseconds: 1000), (timer) {
              _checkNextTaskAvailability();
            });
            _checkNextTaskAvailability(); // 즉시 대기열 2번 녀석 검사 시작
          } else {
            _isMachineBusy = false; // 뒤에 밀린 대기열이 없으면 기계 휴식
          }
        }
      }
    });
  }
  // void _processNextInQueue() {
  //   if (_manufacturingQueue.isEmpty) {
  //     _isMachineBusy = false;
  //     return;
  //   }
  //
  //   _isMachineBusy = true;
  //   final nextTask = _manufacturingQueue.first;
  //
  //   setState(() {
  //     nextTask.subItem.isExtracting = true;
  //     nextTask.subItem.currentStage = "가상 제조 테스트 중...";
  //     nextTask.subItem.logs.insert(0, "🚀 (테스트) 가상 명령 시작 (${nextTask.orderNo})");
  //   });
  //
  //   // 🛑 1. 실제 머신 전송 코드는 잠시 주석 처리! (커피 안 나옴)
  //   // _machineService.sendMakeCommand(nextTask.machineIp, nextTask.productKey, nextTask.orderNo);
  //
  //   // 🧪 2. 가짜 타이머 (5초 뒤에 0x22 완료 신호가 온 것처럼 앱을 속임)
  //   Future.delayed(const Duration(seconds: 26), () {
  //     if (!mounted) return;
  //
  //     setState(() {
  //       // 완료 상태로 강제 변경
  //       nextTask.subItem.progress = 1.0;
  //       nextTask.subItem.status = OrderStatus.ready;
  //       nextTask.subItem.isExtracting = false;
  //       nextTask.subItem.logs.insert(0, "✅ (테스트) 가상 제조 완료");
  //
  //       // 다음 대기열 실행 (0x22 수신했을 때와 동일한 로직)
  //       if (_manufacturingQueue.isNotEmpty) {
  //         _manufacturingQueue.removeAt(0);
  //         _queueNotifier.value++;
  //         _processNextInQueue();
  //       } else {
  //         _isMachineBusy = false;
  //       }
  //     });
  //   });
  // }

  // ---------------------------------------------------------------------------
  // 🚀 nudof 기기 제어 전용 다이얼로그 및 통신 함수들
  // ---------------------------------------------------------------------------

  void _showNudofControlDialog(BuildContext context) {
    // 무게 입력을 위한 로컬 컨트롤러
    final TextEditingController _weightInputController = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Row(
            children: [
              SizedBox(width: 10),
              Text("Nudof 제어 및 교정", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView( // 키보드 대응을 위해 SingleChildScrollView 추가
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("기본 제어", style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 10),
                // 1. 테스트 추출 버튼
                _buildAdminButton("테스트 추출", Icons.water_drop, Colors.blueAccent, () {
                  _runTestExtraction();
                  Navigator.pop(context);
                }),
                const SizedBox(height: 10),
                // 2. 비상 정지 버튼
                _buildAdminButton("펌프 강제 정지", Icons.stop_circle, Colors.redAccent, () {
                  _runEmergencyStop();
                  Navigator.pop(context);
                }),

                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 15),
                  child: Divider(color: Colors.white24),
                ),

                const Text("수동 캘리브레이션 (저울 필수)", style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                const SizedBox(height: 15),

                // Step 1: 교정용 추출
                _buildAdminButton("1. 교정용 추출 시작", Icons.play_arrow, Colors.orange[800]!, () {
                  startCalibrationDispense();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("교정용 추출을 시작합니다.")));
                }),

                const SizedBox(height: 20),

                // Step 2 & 3: 무게 입력 및 전송
                TextField(
                  controller: _weightInputController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: "실측 무게 입력 (g)",
                    labelStyle: const TextStyle(color: Colors.white70),
                    hintText: "예: 20.5",
                    hintStyle: const TextStyle(color: Colors.white24),
                    enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                    focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.orangeAccent)),
                    suffixText: "g",
                    suffixStyle: const TextStyle(color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 10),
                _buildAdminButton("2. 교정 데이터 전송", Icons.send, Colors.green[700]!, () {
                  double? weight = double.tryParse(_weightInputController.text);
                  if (weight != null && weight > 0) {
                    sendCalibrationWeight(weight);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$weight g 교정 데이터를 전송했습니다.")));
                    Navigator.pop(context);
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("올바른 무게를 입력해주세요."), backgroundColor: Colors.red));
                  }
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("닫기", style: TextStyle(color: Colors.white54)),
            ),
          ],
        );
      },
    ).then((_) {
      // 🚀 다이얼로그가 닫힐 때만 포트를 닫음 (InterruptedException 방지)
      _disconnectNudof();
    });
  }

  // 🔌 USB 포트 연결 헬퍼 함수 (중복 코드 방지)
  Future<UsbPort?> _getNudofPort() async {
    List<UsbDevice> devices = await UsbSerial.listDevices();
    if (devices.isEmpty) return null;

    UsbDevice? targetDevice;
    for (var device in devices) {
      if (device.vid != 3034) { // 랜카드 제외
        targetDevice = device;
        break;
      }
    }
    if (targetDevice == null) return null;

    UsbPort? port = await targetDevice.create();
    if (port == null) return null;

    bool openResult = await port.open();
    if (!openResult) return null;

    await port.setPortParameters(38400, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
    return port;
  }

  Uint8List appendModbusCrc(List<int> data) {
    int crc = 0xFFFF;
    for (int b in data) {
      crc ^= b;
      for (int i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    List<int> result = List.from(data);
    result.add(crc & 0xFF);        // 저위 바이트 (Low)
    result.add((crc >> 8) & 0xFF); // 고위 바이트 (High)
    return Uint8List.fromList(result);
  }

  // 🚀 [기능 1] 3단 콤보 추출 (영점 -> 50g -> 가동)
  Future<void> _runTestExtraction() async {
    debugPrint("🚀 [nudof] 블랙박스 모드 가동 (상태 변화 추적)...");
    UsbPort? port = await _getNudofPort();

    if (port == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("USB 연결 실패"), backgroundColor: Colors.red));
      return;
    }

    Completer<bool>? responseCompleter;
    String expectedPrefix = "";

    // ⚠️ 사용하는 펌프 주소
    final int PUMP_ADDRESS = 0x02;

    bool isMonitoring = false; // 블랙박스 가동 스위치
    int lastStatus = -1; // 이전 상태값 기억

    StreamSubscription<Uint8List>? subscription = port.inputStream?.listen((Uint8List event) {
      String rxStrNoSpace = event.map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase()).join('');

      // 1. 내가 보낸 명령의 정상 ACK 확인
      if (expectedPrefix.isNotEmpty && rxStrNoSpace.contains(expectedPrefix)) {
        if (responseCompleter != null && !responseCompleter!.isCompleted) {
          responseCompleter!.complete(true);
        }
      }

      // 2. 🚨 [블랙박스] 0x12 상태값 응답 파싱
      if (isMonitoring && event.length >= 7) {
        if (event[0] == PUMP_ADDRESS && event[1] == 0x03 && event[2] == 0x02) {
          int currentStatus = (event[3] << 8) | event[4];

          // 상태값이 이전과 달라졌을 때만 로그 출력! (멈추는 순간을 포착)
          if (lastStatus != currentStatus) {
            String binaryStatus = currentStatus.toRadixString(2).padLeft(16, '0');
            debugPrint("⚠️ [상태 변화 감지!] 기존: $lastStatus ➔ 현재값: $currentStatus");
            debugPrint("   ➡️ 이진수 비트 분석: $binaryStatus");

            // 문서 기준 간단한 비트 분석
            bool isStandby = (currentStatus & 0x0001) != 0; // Bit 1
            debugPrint("   ➡️ 해석: ${isStandby ? '대기(정지) 상태' : '작업 중(또는 에러)'}");

            lastStatus = currentStatus;
          }
        }
      }
    });

    Future<bool> sendCommandWithRetry(Uint8List command, String cmdName, String prefixHex) async {
      expectedPrefix = prefixHex;
      for (int attempt = 1; attempt <= 3; attempt++) {
        responseCompleter = Completer<bool>();
        await port.write(command);
        try {
          await responseCompleter!.future.timeout(const Duration(milliseconds: 600));
          debugPrint("✅ [$cmdName] 성공!");
          return true;
        } on TimeoutException {
          await Future.delayed(Duration(milliseconds: 300 + Random().nextInt(400)));
        }
      }
      return false;
    }

    try {
      // 🚨 이전에 썼던 센서 무력화(0x18)는 일단 뺐습니다. 순수한 에러 원인을 보기 위함입니다.

      // [1단계] 300g 목표량 세팅
      int targetAmount = 600;
      Uint8List setAmountCmd = appendModbusCrc([
        PUMP_ADDRESS, 0x06, 0x00, 0x02, (targetAmount >> 8) & 0xFF, targetAmount & 0xFF
      ]);
      String setPrefix = "${PUMP_ADDRESS.toRadixString(16).padLeft(2, '0').toUpperCase()}060002";
      bool setSuccess = await sendCommandWithRetry(setAmountCmd, "1단계(300g 목표 세팅)", setPrefix);
      if (!setSuccess) return;

      await Future.delayed(const Duration(milliseconds: 500));

      // [2단계] 펌프 가동
      Uint8List startCmd = appendModbusCrc([PUMP_ADDRESS, 0x06, 0x00, 0x13, 0x00, 0x01]);
      String startPrefix = "${PUMP_ADDRESS.toRadixString(16).padLeft(2, '0').toUpperCase()}060013";
      bool startSuccess = await sendCommandWithRetry(startCmd, "2단계(가동 시작)", startPrefix);

      if (startSuccess) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("블랙박스 모드 가동!"), backgroundColor: Colors.purple));

        // 🌟 [3단계] 가동 직후부터 10초 동안 상태(0x12)를 미친듯이 물어봅니다.
        expectedPrefix = ""; // ACK 대기 해제
        isMonitoring = true; // 리스너에서 파싱 시작
        debugPrint("🕵️‍♂️ 10초간 상태(0x12) 변화를 감시합니다...");

        Uint8List checkStatusCmd = appendModbusCrc([PUMP_ADDRESS, 0x03, 0x00, 0x12, 0x00, 0x01]);

        for (int i = 0; i < 50; i++) { // 0.2초 * 50번 = 10초
          await port.write(checkStatusCmd);
          await Future.delayed(const Duration(milliseconds: 200));
        }

      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("❌ 가동 명령 실패"), backgroundColor: Colors.orange));
      }

    } catch (e) {
      debugPrint("❌ 전송 에러: $e");
    } finally {
      await Future.delayed(const Duration(milliseconds: 300));
      await subscription?.cancel();
      await port.close();
      debugPrint("🏁 블랙박스 감시 종료. 포트 닫힘.");
    }
  }

  // 🛑 [기능 2] 펌프 비상 정지
  Future<void> _runEmergencyStop() async {
    debugPrint("🛑 [nudof] 펌프 강제 정지 시작...");
    UsbPort? port = await _getNudofPort();

    if (port == null) return;

    Completer<bool>? responseCompleter;
    StreamSubscription<Uint8List>? subscription = port.inputStream?.listen((Uint8List event) {
      String rxStr = event.map((e) => e.toRadixString(16).padLeft(2, '0').toUpperCase()).join('');
      if (rxStr.contains("02060014")) { // 정지 명령 응답 매칭
        if (responseCompleter != null && !responseCompleter!.isCompleted) {
          responseCompleter!.complete(true);
        }
      }
    });

    bool isStopped = false;
    try {
      Uint8List stopCmd = appendModbusCrc([0x02, 0x06, 0x00, 0x14, 0x00, 0x01]);

      for (int attempt = 1; attempt <= 3; attempt++) {
        responseCompleter = Completer<bool>();
        await port.write(stopCmd);

        try {
          await responseCompleter!.future.timeout(const Duration(milliseconds: 500));
          isStopped = true;
          break;
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      if (isStopped) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("🛑 펌프 정지 성공!"), backgroundColor: Colors.redAccent));
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("❌ 정지 실패!"), backgroundColor: Colors.red));
      }
    } finally {
      await subscription?.cancel();
      await port.close();
    }
  }

  Future<void> _scanForScaleAddress() async {
    UsbPort? port = await _getNudofPort();
    if (port == null) return;

    debugPrint("🔍 [Scanner] 저울 실무게 스캔 시작... (1~30번 주소)");
    debugPrint("⚠️ 중요: 스캔이 끝날 때까지 저울을 손으로 지그시 누르고 계세요!");

    StreamSubscription<Uint8List>? subscription = port.inputStream?.listen((Uint8List event) {
      // 정상적인 읽기 응답 규격 [주소, 0x03, 0x02, High, Low, CRC, CRC]
      if (event.length >= 7 && event[1] == 0x03 && event[2] == 0x02) {
        int addr = event[0];
        int weight = (event[3] << 8) | event[4];

        // 펌프들(1번~11번)은 센서가 없으니 0g으로 대답하거나 에러를 냅니다.
        // 손으로 누르고 있으므로, 10g 이상의 무게가 잡히는 주소가 무조건 진짜 저울입니다!
        if (weight > 10 && weight < 5000) {
          debugPrint("🎉 [대성공] 진짜 저울 주소 발견! Address: 0x${addr.toRadixString(16).toUpperCase().padLeft(2, '0')}, 현재 측정된 무게: ${weight}g");
        } else {
          // 0g 이라고 대답하는 펌프들은 무시
          // debugPrint("   - Address 0x${addr.toRadixString(16).padLeft(2, '0')} 응답: ${weight}g");
        }
      }
    });

    // 1번부터 30번까지만 스캔 (보통 30번 안에 다 있습니다)
    for (int addr = 1; addr <= 30; addr++) {
      // 0x04(실무게) 레지스터 읽기 명령 발사
      Uint8List scanCmd = appendModbusCrc([addr, 0x03, 0x00, 0x04, 0x00, 0x01]);
      await port.write(scanCmd);
      await Future.delayed(const Duration(milliseconds: 150));
    }

    await Future.delayed(const Duration(seconds: 1));
    await subscription?.cancel();
    await port.close();
    debugPrint("🏁 무게 스캔 종료");
  }

  Future<void> _checkFlowCoefficient() async {
    debugPrint("🔍 [진단] 펌프 보드의 유량 계수(0x21) 확인을 시작합니다...");
    UsbPort? port = await _getNudofPort();

    if (port == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("USB 연결 실패"), backgroundColor: Colors.red));
      return;
    }

    final int PUMP_ADDRESS = 0x02; // ⚠️ 확인하려는 펌프 보드 주소

    StreamSubscription<Uint8List>? subscription = port.inputStream?.listen((Uint8List event) {
      // 🚨 정상적인 읽기 응답: [주소(0x02), 기능코드(0x03), 데이터길이(0x02), HighByte, LowByte, CRC, CRC]
      if (event.length >= 7 && event[0] == PUMP_ADDRESS && event[1] == 0x03 && event[2] == 0x02) {
        int flowCoefficient = (event[3] << 8) | event[4];

        debugPrint("==================================================");
        debugPrint("🚨 [범인 색출!] 펌프 보드에 저장된 유량 계수: $flowCoefficient");
        debugPrint("==================================================");

        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("유량 계수 확인 완료: $flowCoefficient"), backgroundColor: Colors.blue)
        );
      }
    });

    try {
      // 0x21 레지스터 읽기(0x03) 명령 전송
      Uint8List checkCmd = appendModbusCrc([PUMP_ADDRESS, 0x03, 0x00, 0x21, 0x00, 0x01]);
      await port.write(checkCmd);
      debugPrint("📡 0x21 레지스터 읽기 명령 발사!");

      await Future.delayed(const Duration(seconds: 1)); // 1초간 응답 대기

    } catch (e) {
      debugPrint("❌ 전송 에러: $e");
    } finally {
      await subscription?.cancel();
      await port.close();
      debugPrint("🏁 진단 종료. USB 포트 닫힘.");
    }
  }

  Future<void> startCalibrationDispense() async {
    if (!await _connectNudof()) return;

    try {
      Uint8List startCmd = appendModbusCrc([0x02, 0x06, 0x00, 0x09, 0x00, 0x01]);
      await _nudofPort!.write(startCmd); // 전역 포트 사용
      debugPrint("📡 [Step 1] 교정용 추출 시작 명령 발사!");
    } catch (e) {
      debugPrint("❌ 전송 에러: $e");
    }
    // 🚨 close() 제거!
  }

  Future<void> sendCalibrationWeight(double realWeight) async {
    if (!await _connectNudof()) return;

    try {
      int weightValue = (realWeight * 10).toInt();
      Uint8List feedbackCmd = appendModbusCrc([
        0x02, 0x06, 0x00, 0x10,
        (weightValue >> 8) & 0xFF,
        weightValue & 0xFF
      ]);

      await _nudofPort!.write(feedbackCmd);
      debugPrint("📡 [Step 3] 실제 무게($realWeight g) 피드백 완료!");
    } catch (e) {
      debugPrint("❌ 전송 에러: $e");
    }
    // 🚨 close() 제거!
  }

  UsbPort? _nudofPort;

  Future<bool> _connectNudof() async {
    if (_nudofPort != null) return true;

    List<UsbDevice> devices = await UsbSerial.listDevices();
    if (devices.isEmpty) {
      debugPrint("❌ 연결된 USB 장치가 없습니다.");
      return false;
    }

    UsbDevice? targetDevice = devices.firstWhere((d) => d.vid != 3034, orElse: () => devices.first);
    UsbPort? port = await targetDevice.create();
    if (port == null) return false;

    bool openResult = await port.open();
    if (!openResult) return false;

    await port.setPortParameters(38400, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
    _nudofPort = port;
    debugPrint("🔌 Nudof 포트 연결 성공");
    return true;
  }

  // 🔌 포트 해제 (다이얼로그 닫힐 때 호출)
  Future<void> _disconnectNudof() async {
    if (_nudofPort != null) {
      await Future.delayed(const Duration(milliseconds: 300));
      await _nudofPort!.close();
      _nudofPort = null;
      debugPrint("🔌 Nudof 포트 해제 완료");
    }
  }
}
