import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle; // CSV 로드용
import 'package:csv/csv.dart'; // CSV 파싱용
import '../components/order_card_widget.dart';
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
    //_startUsbHeartbeat();
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
              onPressed: () => _showMachineManagementDialog(context),
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
    );
  }

  void _showMachineManagementDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Center(child: const Text("CAYE 머신 원격 관리", style: TextStyle(color: Colors.white))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildAdminButton("네트워크 연결 확인 (Ping)", Icons.lan, Colors.teal, () async {
              bool isAlive = await _machineService.checkNetworkOnly("192.168.10.193");
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  backgroundColor: isAlive ? Colors.green : Colors.red,
                  content: Text(isAlive ? "[Caye] 기기 연결됨 (물리적 성공)" : "[Caye] 기기 연결 실패 (IP/랜선 확인)"),
                ),
              );
            }),
            const SizedBox(height: 20),
            _buildAdminButton("시간 동기화 (Ping)", Icons.sync, Colors.blue, () {
              _machineService.sendTimeSyncCommand("192.168.10.193"); // 0x00
            }),
            const SizedBox(height: 10),
            _buildAdminButton("기기 세척 (Cleaning)", Icons.cleaning_services, Colors.orange, () {
              _machineService.sendCleaningCommand("192.168.10.193"); // 0x01
            }),
            const SizedBox(height: 10),
            _buildAdminButton("기기 헹굼 (Rinsing)", Icons.water_drop, Colors.cyan, () {
              _machineService.sendRinsingCommand("192.168.10.193"); // 0x10
            }),
            const SizedBox(height: 10),
            _buildAdminButton("현재 상태 조회", Icons.info_outline, Colors.purple, () {
              _machineService.sendQueryStatus("192.168.10.193"); // 0x31
            }),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("닫기")),
        ],
      ),
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

  // Widget _buildRemoteController() {
  //   final List<int> gridMapping = [
  //     1, 5, 2,
  //     8, 0, 6,
  //     4, 7, 3,
  //   ];
  //   return Container(
  //     color: Colors.black,
  //     padding: const EdgeInsets.all(30),
  //     child: Column(
  //       children: [
  //         const Text("미세 보정 컨트롤", style: TextStyle(color: Colors.orangeAccent, fontSize: 28, fontWeight: FontWeight.bold)),
  //         const Spacer(),
  //
  //         // 1. 원형 숫자 패드 (물리적 배치와 동일)
  //         SizedBox(
  //           width: 400,
  //           child: GridView.builder(
  //             shrinkWrap: true,
  //             gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
  //                 crossAxisCount: 3, mainAxisSpacing: 20, crossAxisSpacing: 20),
  //             itemCount: 9,
  //             itemBuilder: (context, index) {
  //               int pointIndex = gridMapping[index];
  //               bool isSelected = _selectedPoint == pointIndex;
  //               return ElevatedButton(
  //                 style: ElevatedButton.styleFrom(
  //                   shape: const CircleBorder(), // 👈 원형으로 변경
  //                   padding: const EdgeInsets.all(20),
  //                   backgroundColor: isSelected ? Colors.orangeAccent : Colors.grey[800],
  //                 ),
  //                 onPressed: () {
  //                   setState(() => _selectedPoint = pointIndex);
  //                   _socketService.sendFineTuneControl("SELECT", value: pointIndex);
  //                 },
  //                 child: Text("${pointIndex + 1}", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
  //               );
  //             },
  //           ),
  //         ),
  //
  //         const Spacer(),
  //
  //         // 2. 방향키 (미세 이동)
  //         Row(
  //           mainAxisAlignment: MainAxisAlignment.center,
  //           children: [
  //             _dirBtn(Icons.arrow_back, -1, 0),
  //             Column(
  //               children: [
  //                 _dirBtn(Icons.arrow_upward, 0, -1),
  //                 const SizedBox(height: 60), // 상하 버튼 간격
  //                 _dirBtn(Icons.arrow_downward, 0, 1),
  //               ],
  //             ),
  //             _dirBtn(Icons.arrow_forward, 1, 0),
  //           ],
  //         ),
  //
  //         const Spacer(),
  //
  //         ElevatedButton(
  //           style: ElevatedButton.styleFrom(
  //             backgroundColor: Colors.green[700],
  //             minimumSize: const Size(double.infinity, 80),
  //             shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
  //           ),
  //           onPressed: () {
  //             _socketService.sendFineTuneControl("COMPLETE");
  //           },
  //           child: const Text("미세 조정 완료", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  // Widget _dirBtn(IconData icon, double dx, double dy) {
  //   return GestureDetector(
  //     onTap: () => _socketService.sendFineTuneControl("MOVE", value: {"dx": dx, "dy": dy}),
  //     child: Container(
  //       width: 70, height: 70,
  //       margin: const EdgeInsets.all(5),
  //       decoration: const BoxDecoration(color: Colors.blueAccent, shape: BoxShape.circle),
  //       child: Icon(icon, color: Colors.white, size: 35),
  //     ),
  //   );
  // }

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
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          subItem.menuName,
                          style: TextStyle(
                            color: isSubReady ? Colors.white38 : Colors.white,
                            fontSize: 16,
                            decoration: isSubReady ? TextDecoration.lineThrough : null, // 완료 시 취소선
                          ),
                        ),
                      ),

                      IconButton(
                        icon: const Icon(Icons.play_circle_fill, color: Colors.orangeAccent, size: 28),
                        tooltip: "머신 추출 테스트",
                        onPressed: () {
                          String? pKey;

                          // 💡 레시피 매핑 (머신에 1, 2번으로 등록했다고 가정)
                          if (subItem.menuName.contains("아메리카노")) {
                            pKey = "1";
                          } else if (subItem.menuName.contains("라떼")) {
                            pKey = "2";
                          }

                          if (pKey != null) {
                            // 레시피가 있는 경우 -> 제조 명령 전송
                            _machineService.sendMakeCommand(
                                "192.168.10.193",
                                pKey,
                                "${order.orderNo}.${(index + 1).toString().padLeft(2, '0')}"
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text("🚀 ${subItem.menuName} 추출 시작!")),
                            );
                          } else {
                            // 레시피가 없는 경우 -> 경고 표시 (동작 안 함)
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                backgroundColor: Colors.redAccent,
                                content: Text("⚠️ 해당 메뉴는 머신 레시피가 등록되지 않았습니다."),
                              ),
                            );
                          }
                        },
                      ),

                      const SizedBox(width: 8),
                      // 개별 제조완료 버튼
                      SizedBox(
                        width: 70,
                        height: 35,
                        child: ElevatedButton(
                          onPressed: isSubReady ? null : () {
                            setState(() {
                              subItem.status = OrderStatus.ready;
                            });
                            // 필요 시 소켓으로 부분 완료 신호 전송
                            _socketService.sendOrderReady(
                                order,
                                subItem.menuName
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green[700],
                            padding: EdgeInsets.zero,
                          ),
                          child: Text(isSubReady ? "제조완료" : "제조중", style: const TextStyle(fontSize: 12)),
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
}
