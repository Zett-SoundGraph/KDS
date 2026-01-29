import 'dart:math';

import 'package:flutter/material.dart';
import '../models/order_item.dart';
import '../services/socket_service.dart';

class KdsMainScreen extends StatefulWidget {
  const KdsMainScreen({super.key});

  @override
  State<KdsMainScreen> createState() => _KdsMainScreenState();
}

class _KdsMainScreenState extends State<KdsMainScreen> {
  // 1. 소켓 서비스 인스턴스 생성
  final KdsSocketService _socketService = KdsSocketService();

  // 테스트용 임시 데이터
  final List<OrderItem> _orders = List.generate(
    15,
        (index) => OrderItem(orderNo: "${100 + index + 1}", menuName: "주문 메뉴 ${index + 1}"),
  );

  @override
  void initState() {
    super.initState();
    // 2. 앱 시작 시 픽업 테이블 서버에 접속 시도
    _socketService.connectToServer();

    _socketService.onPickupSignalReceived = (orderNo) {
      setState(() {
        // 리스트에서 해당 주문 번호를 가진 아이템을 찾아 삭제
        _orders.removeWhere((order) {
          if (order.orderNo == orderNo) {
            print("✅ 서버 신호에 의해 $orderNo번 주문이 자동 픽업 처리됨");
            return true;
          }
          return false;
        });
      });

      // 알림 표시 (옵션)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("테이블에서 $orderNo번 픽업이 확인되었습니다."), duration: const Duration(seconds: 1)),
      );
    };
  }

  // 3. [제조 완료] 버튼 클릭 시 실행될 함수
  void _onCompleteCooking(OrderItem order) {
    setState(() {
      order.status = OrderStatus.ready; // 화면 상태를 '준비됨'으로 변경
    });

    // 🚀 소켓을 통해 서버로 "READY:주문번호" 신호 전송
    _socketService.sendOrderReady(order.orderNo, order.menuName);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("${order.orderNo}번 제조 완료 신호를 보냈습니다.")),
    );
  }

  // 4. [픽업 완료] 버튼 클릭 시 실행될 함수
  void _onCompletePickup(OrderItem order) {
    setState(() {
      _orders.remove(order);
      order.status = OrderStatus.pending;
      _orders.add(order); // 리스트 맨 뒤로 보냄
    });
  }

  @override
  void dispose() {
    _socketService.dispose(); // 앱 종료 시 소켓 닫기
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("KDS", style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.blueGrey[900],
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3, // 3x3 그리드
            childAspectRatio: 1.2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
          ),
          //itemCount: 9, // 화면에는 상위 9개만 노출
          itemCount: min(_orders.length, 9),
          itemBuilder: (context, index) {
            final order = _orders[index];
            return _buildOrderCard(order);
          },
        ),
      ),
    );
  }

  Widget _buildOrderCard(OrderItem order) {
    bool isReady = order.status == OrderStatus.ready;

    return Container(
      decoration: BoxDecoration(
        color: isReady ? Colors.indigo[900] : Colors.grey[900],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isReady ? Colors.blueAccent : Colors.white10, width: 2),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("NO. ${order.orderNo}", style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
          const Divider(color: Colors.white24, height: 20),
          Expanded(child: Text(order.menuName, style: const TextStyle(fontSize: 18, color: Colors.white70))),
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: isReady ? null : () => _onCompleteCooking(order),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green[800]),
                  child: const Text(
                    "제조완료",
                    style: TextStyle(
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: !isReady ? null : () => _onCompletePickup(order),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red[900]),
                  child: const Text("픽업완료",
                    style: TextStyle(
                      fontSize: 11,
                    ),),
                ),
              ),
            ],
          )
        ],
      ),
    );
  }
}