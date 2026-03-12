import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle; // CSV 로드용
import 'package:csv/csv.dart'; // CSV 파싱용
import '../models/order_item.dart';
import '../services/socket_service.dart';
import '../services/test_name_provider.dart';

class KdsMainScreen extends StatefulWidget {
  const KdsMainScreen({super.key});

  @override
  State<KdsMainScreen> createState() => _KdsMainScreenState();
}

class _KdsMainScreenState extends State<KdsMainScreen> {
  // 1. 소켓 서비스 인스턴스 생성
  final KdsSocketService _socketService = KdsSocketService();
  final PageController _pageController = PageController();

  List<OrderItem> _orders = [];
  bool _isLoading = true;
  int _currentPage = 0;
  bool _isRemoteCalibrating = false;
  int _selectedPoint = 0;
  bool _isCalibOverlayVisible = false;
  bool _isRemoteVisible = false;

  @override
  void initState() {
    super.initState();
    _socketService.connectToServer();
    _loadCsvData();

    _socketService.onStatusChanged = (status) {
      if (!mounted) return;
      setState(() {
        if (status == "ENTER_FINE_TUNE") {
          _selectedPoint = 0;
          _isCalibOverlayVisible = false; // 차단막 닫고
          _isRemoteVisible = true;       // 리모컨 켬
        } else if (status == "VALIDATION_MODE") {
          _isCalibOverlayVisible = true;  // 리모컨 닫고 차단막 켬
          _isRemoteVisible = false;
        } else if (status == "CALIB_EXIT") {
          _isCalibOverlayVisible = false; // 모두 닫고 주문 목록으로
          _isRemoteVisible = false;
          _selectedPoint = 0;
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
      int currentSequence = 101;
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
  void _onStartCalibration() {
    _socketService.sendStartCalibration();
    setState(() {
      _selectedPoint = 0;
      _isCalibOverlayVisible = true;
      _isRemoteVisible = false;
      _isRemoteCalibrating = true;
    });
  }

  @override
  void dispose() {
    _socketService.dispose(); // 앱 종료 시 소켓 닫기
    _pageController.dispose();
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
              if (_isRemoteVisible)
                Positioned.fill(child: _buildRemoteController()),

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

  Widget _buildRemoteController() {
    final List<int> gridMapping = [
      1, 5, 2,
      8, 0, 6,
      4, 7, 3,
    ];
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(30),
      child: Column(
        children: [
          const Text("미세 보정 컨트롤", style: TextStyle(color: Colors.orangeAccent, fontSize: 28, fontWeight: FontWeight.bold)),
          const Spacer(),

          // 1. 원형 숫자 패드 (물리적 배치와 동일)
          SizedBox(
            width: 400,
            child: GridView.builder(
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3, mainAxisSpacing: 20, crossAxisSpacing: 20),
              itemCount: 9,
              itemBuilder: (context, index) {
                int pointIndex = gridMapping[index];
                bool isSelected = _selectedPoint == pointIndex;
                return ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    shape: const CircleBorder(), // 👈 원형으로 변경
                    padding: const EdgeInsets.all(20),
                    backgroundColor: isSelected ? Colors.orangeAccent : Colors.grey[800],
                  ),
                  onPressed: () {
                    setState(() => _selectedPoint = pointIndex);
                    _socketService.sendFineTuneControl("SELECT", value: pointIndex);
                  },
                  child: Text("${pointIndex + 1}", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                );
              },
            ),
          ),

          const Spacer(),

          // 2. 방향키 (미세 이동)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _dirBtn(Icons.arrow_back, -1, 0),
              Column(
                children: [
                  _dirBtn(Icons.arrow_upward, 0, -1),
                  const SizedBox(height: 60), // 상하 버튼 간격
                  _dirBtn(Icons.arrow_downward, 0, 1),
                ],
              ),
              _dirBtn(Icons.arrow_forward, 1, 0),
            ],
          ),

          const Spacer(),

          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green[700],
              minimumSize: const Size(double.infinity, 80),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
            ),
            onPressed: () {
              _socketService.sendFineTuneControl("COMPLETE");
            },
            child: const Text("미세 조정 완료", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _dirBtn(IconData icon, double dx, double dy) {
    return GestureDetector(
      onTap: () => _socketService.sendFineTuneControl("MOVE", value: {"dx": dx, "dy": dy}),
      child: Container(
        width: 70, height: 70,
        margin: const EdgeInsets.all(5),
        decoration: const BoxDecoration(color: Colors.blueAccent, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white, size: 35),
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
            Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
            SizedBox(width: 10),
            Text("정밀보정 시작", style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Text(
          "픽업 테이블의 좌표 보정을 시작하시겠습니까?\n\n시작하면 픽업 테이블 화면이 보정 모드로 전환되며, 완료 전까지는 정상적인 서비스 이용이 제한됩니다.",
          style: TextStyle(color: Colors.white70, height: 1.5),
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
              _onStartCalibration();
              _socketService.sendStartCalibration(); // "START_CALIBRATION" 신호 전송
              Navigator.pop(context);

              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("픽업 테이블로 보정 신호를 보냈습니다.")),
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
