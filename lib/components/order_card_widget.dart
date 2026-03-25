import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class OrderCardWidget extends StatelessWidget {
  final String orderNo;
  final List<String> menus;

  const OrderCardWidget({Key? key, required this.orderNo, required this.menus}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 384, // 58mm 프린터 물리적 최대 폭
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: Colors.black,
          width: 1, // 🚀 대칭 확인용 테두리 (확인 후 0으로 변경 가능)
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 15),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. QR 코드 (상단 배치)
          QrImageView(
            data: orderNo,
            size: 160.0, // 메뉴 리스트를 위해 크기를 살짝 조정 (240 -> 160)
            gapless: false,
          ),
          const SizedBox(height: 10),

          // 2. 주문 번호 강조
          Text(
            "NO. $orderNo",
            style: const TextStyle(fontSize: 50, fontWeight: FontWeight.bold, color: Colors.black),
          ),

          const Divider(color: Colors.black, thickness: 3), // 구분선
          const SizedBox(height: 10),

          // 🚀 3. 메뉴 리스트 (실제 데이터 10개를 그리는 부분)
          // Column 내부에 리스트를 풀어서 넣습니다.
          ...menus.map((menu) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft, // 메뉴명은 왼쪽 정렬이 읽기 편함
              child: Text(
                "• $menu",
                style: const TextStyle(
                  fontSize: 24, // 프린터에서 잘 보이는 큼직한 크기
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
            ),
          )).toList(),

          const SizedBox(height: 20),
          const Divider(color: Colors.black, thickness: 1),

          const Text(
            "[ KDS IMAGE MODE TEST ]",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black),
          ),

          const SizedBox(height: 120), // 용지 배출(커팅) 여백
        ],
      ),
    );
  }
}