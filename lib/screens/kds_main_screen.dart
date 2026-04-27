import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle; // CSV 로드용
import 'package:csv/csv.dart'; // CSV 파싱용
import 'package:kds/screens/caye_management_screen.dart';
import '../components/extraction_monitor_dialog.dart';
import '../components/order_card_widget.dart';
import '../models/manufacturing_queue_item.dart';
import '../models/order_item.dart';
import '../services/machine_bridge_service.dart';
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

  final PrinterService _printerService = PrinterService();

  @override
  void initState() {
    super.initState();
    _printerService.listenToLabels(
      onDetached: () {
        print("📢 [확인] 프린터에서 라벨이 제거되었습니다.");
      },
      onAttached: () {
        print("📢 [확인] 프린터에 라벨이 감지되었습니다.");
      },
    );
    _socketService.connectToServer();
    _loadCsvData();

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
          content: Text("$orderNo번 주문의 $menuName 픽업 확인!"),
          duration: const Duration(seconds: 1),
        ),
      );
    };
    _machineService.extractionStream.listen((progressData) {
      _updateGlobalExtractionState(progressData);
    });
    //_startUsbHeartbeat();
  }

  void _updateGlobalExtractionState(ExtractionProgress progress) {
    final data = progress.data;
    if (progress.code == 0x23) {
      debugPrint("🔍 [0x23 상태 보고] $data");

      // 🚀 [해결 2] 머신의 응답 키값은 'beverageStatus' 입니다!
      int bevStatus = data['beverageStatus'] ?? -1;

      // 1은 바쁨, 0이 대기(가능) 상태입니다.
      if (bevStatus == 1) {
        debugPrint("🟢 기기 준비 완료(1)! 루프 종료 및 제조 명령(0x20) 발사!");
        _availabilityTimer?.cancel(); // 루프 정지!
        _acceptMachinePackets = false; // 혹시 모르니 발사 전 한 번 더 방어막 확인
        _processNextInQueue(); // 진짜 명령 쏘기!
      } else {
        debugPrint("🔴 기기 아직 바쁨 (상태값: $bevStatus)... 다음 루프 대기");
      }
      return;
    }
    if (progress.code == 0x20) {
      if (data['result'] == 0) {
        // 머신이 바빠서 거절함 -> 0.5초(500ms) 뒤에 현재 대기열 첫 번째 항목 다시 전송!
        debugPrint("⚠️ 머신 바쁨 (result: 0) -> 0.5초 후 재시도...");
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _manufacturingQueue.isNotEmpty) {
            final retryTask = _manufacturingQueue.first;
            _machineService.sendMakeCommand(retryTask.machineIp, retryTask.productKey, retryTask.orderNo);
          }
        });
      } else if (data['result'] == 1) {
        // 수락됨! 본격적인 추출 시작
        debugPrint("✅ 머신 수락 (result: 1) -> 추출 대기...");
        _acceptMachinePackets = true;
      }
      return; // 0x20 패킷은 여기서 처리 끝 (아래의 게이지바 로직으로 안 내려감)
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
        item.currentStage = "에스프레소 추출 중...";
        newLog = "💧 ${data['coffeeWaterQuantity']}ml / 🌡️ ${data['boilerTemp']}°C";
      } else if (powder > 0) {
        item.progress = ((powder / targetPowder) * 0.3).clamp(0.0, 0.3);
        item.currentStage = "원두 분쇄 중...";
        newLog = "🫘 원두 분쇄 중: $powder g";
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
        newLog = "✅ 제조 완료";

        // 서버 동기화 (기존 로직 유지)
        _socketService.sendOrderReady(order, item.menuName);
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
        newLog = "❌ 에러 발생: ${item.errorCode}";
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

  @override
  void dispose() {
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
      return const Scaffold(
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
    if (orientation == Orientation.portrait) {
      rowCount = 3; // 세로 모드에선 무조건 3줄
    } else {
      // 가로 모드일 때 세로 높이가 너무 낮으면 1줄, 적당하면 2줄
      if (screenSize.height < 500) {
        rowCount = 1;
      } else if (screenSize.height < 800) {
        rowCount = 2;
      } else {
        rowCount = 3;
      }
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
              label: const Text("머신 관리", style: TextStyle(fontWeight: FontWeight.bold)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.greenAccent, width: 1.5),
                foregroundColor: Colors.greenAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: OutlinedButton(
              onPressed: () => _printerService.printTest(testMenus),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.cyanAccent, width: 1.5),
                foregroundColor: Colors.cyanAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text("텍스트출력", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),

          // 2. 새로운 이미지 방식 (테스트 대상) 🚀 추가된 부분
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: OutlinedButton(
              onPressed: () {
                // 테스트용 데이터로 위젯 생성하여 전달
                _printerService.printImageLabel(OrderCardWidget(orderNo: "105", menus: testMenus));
              },
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.cyanAccent, width: 1.5),
                foregroundColor: Colors.cyanAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text("이미지출력", style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: OutlinedButton(
              onPressed: () => _showCalibrationConfirmDialog(context),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.orangeAccent, width: 1.5),
                foregroundColor: Colors.orangeAccent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: const Text(
                "정밀보정",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ],
        backgroundColor: Colors.blueGrey[900],
        centerTitle: true,
      ),
      body: Stack(
            children: [
              _orders.isEmpty
                  ? const Center(child: Text("주문 데이터가 없습니다.", style: TextStyle(color: Colors.white)))
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
                        const Text("픽업 테이블 보정 진행 중...",
                            style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 10),
                        const Text("픽업 테이블의 안내에 따라 컵을 옮겨주세요.",
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
              ? "대기열 없음"
              : "대기열 ${_manufacturingQueue.length}개",
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
                    Text("제조 대기열", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ],
                ),
                content: SizedBox(
                  width: 350,
                  height: 300, // 스크롤 가능하도록 높이 고정
                  child: _manufacturingQueue.isEmpty
                      ? const Center(child: Text("대기 중인 제조 명령이 없습니다.", style: TextStyle(color: Colors.white54)))
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
                        subtitle: Text("주문 번호: ${item.orderNo}", style: const TextStyle(color: Colors.white54)),
                        trailing: isExtracting
                            ? const Text("제조 중...", style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold))
                            : const Text("대기 중", style: TextStyle(color: Colors.white30)),
                      );
                    },
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("닫기", style: TextStyle(color: Colors.white)),
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
            Text("설치 높이 입력", style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "현재 설치된 센서의 높이(mm)를 입력해주세요.\n정확한 보정을 위해 필수적인 값입니다.",
              style: TextStyle(color: Colors.white70, height: 1.5, fontSize: 14),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _heightController,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                labelText: "설치 높이 (mm 단위)",
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
            child: const Text("취소", style: TextStyle(color: Colors.white54)),
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
                SnackBar(content: Text("설치 높이 ${inputHeight.toInt()}mm 설정 및 보정 시작")),
              );
            },
            child: const Text("보정 시작"),
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
          Text("NO. ${order.orderNo}", style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
          if (order.nickname != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: Colors.orangeAccent, borderRadius: BorderRadius.circular(4)),
              child: Text(order.nickname!,
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14)),
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
                            showExtractionMonitor(
                              context, _machineService, subItem.menuName,
                              machineIp: "192.168.10.193",
                              productKey: (subItem.menuName.contains("아메리카노") ? "1" : "2"),
                              orderNo: order.orderNo,
                              subItem: subItem,
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
            child: const Text("픽업 완료", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _startManufacturing(OrderItem order, SubItem subItem, int index) {
    const String machineIp = "192.168.10.193";
    String? pKey;
    if (subItem.menuName.contains("아메리카노")) pKey = "1";
    else if (subItem.menuName.contains("라떼")) pKey = "2";

    if (pKey != null) {
      String combinedOrderNo = "${order.orderNo}.${(index + 1).toString().padLeft(2, '0')}";

      // 1. 큐 아이템 생성
      final newItem = ManufacturingQueueItem(
        machineIp: machineIp,
        productKey: pKey,
        orderNo: combinedOrderNo,
        subItem: subItem,
        order: order,
      );

      setState(() {
        // 2. 큐에 추가
        _manufacturingQueue.add(newItem);
        subItem.logs = ["⏳ 제조 대기열에 추가됨..."];
        subItem.currentStage = "대기 중";
        subItem.isExtracting = true;
        _queueNotifier.value++;
      });

      // 3. 머신이 쉬고 있다면 바로 첫 번째 작업 시작
      if (!_isMachineBusy) {
        _processNextInQueue();
      }
    }
  }

  List<ManufacturingQueueItem> _manufacturingQueue = [];
  bool _isMachineBusy = false; // 현재 머신이 제조 중인지 여부
  bool _acceptMachinePackets = false;

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
      nextTask.subItem.logs.insert(0, "🚀 제조 명령 전송됨 (${nextTask.orderNo})");
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
      nextTask.subItem.currentStage = "기기 준비 상태 확인 중...";
    });

    // 0x23 발사!
    _machineService.sendCheckAvailability(nextTask.machineIp, nextTask.productKey);
  }
//   void _processNextInQueue() {
//     if (_manufacturingQueue.isEmpty) {
//       _isMachineBusy = false;
//       return;
//     }
//
//     _isMachineBusy = true;
//     final nextTask = _manufacturingQueue.first;
//
//     setState(() {
//       nextTask.subItem.isExtracting = true;
//       nextTask.subItem.currentStage = "가상 제조 테스트 중...";
//       nextTask.subItem.logs.insert(0, "🚀 (테스트) 가상 명령 시작 (${nextTask.orderNo})");
//     });
//
//     // 🛑 1. 실제 머신 전송 코드는 잠시 주석 처리! (커피 안 나옴)
//     // _machineService.sendMakeCommand(nextTask.machineIp, nextTask.productKey, nextTask.orderNo);
//
//     // 🧪 2. 가짜 타이머 (5초 뒤에 0x22 완료 신호가 온 것처럼 앱을 속임)
//     Future.delayed(const Duration(seconds: 26), () {
//       if (!mounted) return;
//
//       setState(() {
//         // 완료 상태로 강제 변경
//         nextTask.subItem.progress = 1.0;
//         nextTask.subItem.status = OrderStatus.ready;
//         nextTask.subItem.isExtracting = false;
//         nextTask.subItem.logs.insert(0, "✅ (테스트) 가상 제조 완료");
//
//         // 다음 대기열 실행 (0x22 수신했을 때와 동일한 로직)
//         if (_manufacturingQueue.isNotEmpty) {
//           _manufacturingQueue.removeAt(0);
//           _queueNotifier.value++;
//           _processNextInQueue();
//         } else {
//           _isMachineBusy = false;
//         }
//       });
//     });
//   }
}
