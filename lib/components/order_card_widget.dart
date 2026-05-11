import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/menu_recipe.dart';
import '../services/recipe_manager.dart';

class OrderCardWidget extends StatelessWidget {
  final String orderNo;
  final String sequence;
  final String totalSequence;
  final List<String> menus;
  final String qrData;

  const OrderCardWidget({
    Key? key,
    required this.orderNo,
    this.sequence = "01",
    this.totalSequence = "02",
    required this.menus,
    required this.qrData
  }) : super(key: key);

  @override
  // Widget build(BuildContext context) {
  //   return Container(
  //     width: 384, // 58mm 프린터 물리적 최대 폭
  //     decoration: BoxDecoration(
  //       color: Colors.white,
  //       border: Border.all(
  //         color: Colors.black,
  //         width: 1, // 🚀 대칭 확인용 테두리 (확인 후 0으로 변경 가능)
  //       ),
  //     ),
  //     padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 15),
  //     child: Column(
  //       mainAxisSize: MainAxisSize.min,
  //       crossAxisAlignment: CrossAxisAlignment.center,
  //       children: [
  //         // 1. QR 코드 (상단 배치)
  //         QrImageView(
  //           data: qrData,
  //           size: 160.0, // 메뉴 리스트를 위해 크기를 살짝 조정 (240 -> 160)
  //           gapless: false,
  //         ),
  //         const SizedBox(height: 10),
  //
  //         // 2. 주문 번호 강조
  //         Text(
  //           "NO. $orderNo",
  //           style: const TextStyle(fontSize: 50, fontWeight: FontWeight.bold, color: Colors.black),
  //         ),
  //
  //         const Divider(color: Colors.black, thickness: 3), // 구분선
  //         const SizedBox(height: 10),
  //
  //         // 🚀 3. 메뉴 리스트 (실제 데이터 10개를 그리는 부분)
  //         // Column 내부에 리스트를 풀어서 넣습니다.
  //         ...menus.map((menu) => Padding(
  //           padding: const EdgeInsets.symmetric(vertical: 4),
  //           child: Align(
  //             alignment: Alignment.centerLeft, // 메뉴명은 왼쪽 정렬이 읽기 편함
  //             child: Text(
  //               "• $menu",
  //               style: const TextStyle(
  //                 fontSize: 24, // 프린터에서 잘 보이는 큼직한 크기
  //                 fontWeight: FontWeight.w600,
  //                 color: Colors.black,
  //               ),
  //             ),
  //           ),
  //         )).toList(),
  //
  //         const SizedBox(height: 20),
  //         const Divider(color: Colors.black, thickness: 1),
  //
  //         const Text(
  //           "[ KDS IMAGE MODE TEST ]",
  //           style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black),
  //         ),
  //
  //         const SizedBox(height: 20), // 용지 배출(커팅) 여백
  //       ],
  //     ),
  //   );
  // }
  /// 주문 번호 상단
  // Widget build(BuildContext context) {
  //   // ----------------------------------------------------
  //   // [프린터 DPI에 맞춘 강제 스케일업 스타일 지정]
  //   // ----------------------------------------------------
  //
  //   // 3. Product & Option 스타일 (14px -> 24px로 약 1.7배 확대)
  //   const TextStyle productOptionStyle = TextStyle(
  //     fontFamily: 'JetBrainsMono',
  //     fontWeight: FontWeight.w400,
  //     fontSize: 24.0,
  //     height: 1.1, // 줄간격을 최대한 좁혀서 빼곡한 느낌 강조
  //     letterSpacing: -0.5,
  //     color: Colors.black,
  //   );
  //
  //   // 4. 하단 부분 스타일 (14px -> 20px로 확대)
  //   const TextStyle footerStyle = TextStyle(
  //     fontFamily: 'JetBrainsMono',
  //     fontWeight: FontWeight.w400,
  //     fontSize: 20.0,
  //     height: 1.1,
  //     letterSpacing: -0.5,
  //     color: Colors.black,
  //   );
  //
  //   final String currentTime = DateTime.now().toString().substring(0, 19);
  //
  //   return Container(
  //     width: 384, // 58mm 프린터 가로폭 절대 고정
  //     color: Colors.white,
  //     // 🚀 상하좌우 여백을 완전히 0으로 설정! (프린터 하드웨어 자체의 최소 1~2mm 여백만 남게 됩니다)
  //     padding: EdgeInsets.zero,
  //     child: Column(
  //       mainAxisSize: MainAxisSize.min,
  //       crossAxisAlignment: CrossAxisAlignment.start, // 왼쪽 꽉 채움 정렬
  //       children: [
  //         // ----------------------------------------------------
  //         // 1. 주문번호 & 2. QR 영역
  //         // ----------------------------------------------------
  //         Row(
  //           crossAxisAlignment: CrossAxisAlignment.start,
  //           mainAxisAlignment: MainAxisAlignment.spaceBetween,
  //           children: [
  //             Expanded(
  //               child: Padding(
  //                 padding: const EdgeInsets.only(top: 8.0), // QR과 상단 라인을 맞추기 위한 미세조정
  //                 child: RichText(
  //                   text: TextSpan(
  //                     style: const TextStyle(
  //                       fontFamily: 'JetBrainsMono',
  //                       fontWeight: FontWeight.w700, // 가장 두껍게
  //                       fontSize: 60.0, // 40px -> 60px 대폭 확대
  //                       height: 1.0,
  //                       letterSpacing: -1.5, // 자간을 좁혀서 가로 길이를 아낌
  //                       color: Colors.black,
  //                     ),
  //                     children: [
  //                       TextSpan(text: orderNo),
  //                       TextSpan(
  //                         text: ".$sequence/$totalSequence",
  //                         style: const TextStyle(fontSize: 32.0), // 24px -> 32px 확대
  //                       ),
  //                     ],
  //                   ),
  //                 ),
  //               ),
  //             ),
  //             // 2. QR 영역 (100 -> 120으로 확대하여 우측에 꽉 차게 배치)
  //             SizedBox(
  //               width: 120.0,
  //               height: 120.0,
  //               child: QrImageView(
  //                 data: qrData,
  //                 size: 120.0,
  //                 padding: EdgeInsets.zero, // QR 내부 여백 제거
  //                 gapless: false,
  //               ),
  //             ),
  //           ],
  //         ),
  //
  //         const SizedBox(height: 8), // 간격 축소
  //
  //         // ----------------------------------------------------
  //         // 3. Product & Option 영역
  //         // ----------------------------------------------------
  //         Text("[PRODUCT]", style: productOptionStyle.copyWith(fontWeight: FontWeight.w700)),
  //         Text(
  //           menus.isNotEmpty ? menus.first : "ICED AMERICANO",
  //           style: productOptionStyle.copyWith(fontSize: 24),
  //         ),
  //         Text("Version: 0.94.0506.02", style: productOptionStyle.copyWith(fontSize: 24)),
  //
  //         const SizedBox(height: 24), // 간격 축소
  //
  //         Text("[OPTION]", style: productOptionStyle.copyWith(fontWeight: FontWeight.w700)),
  //         Text("- BEAN: BETA_DARK_ROAST", style: productOptionStyle.copyWith(fontSize: 24)),
  //         Text("- ADD_SHOT: +1 (TOTAL 3)", style: productOptionStyle.copyWith(fontSize: 24)),
  //         Text("- WATER: 250ml", style: productOptionStyle.copyWith(fontSize: 24)),
  //         Text("- TEMP: ICED (DEFAULT)", style: productOptionStyle.copyWith(fontSize: 24)),
  //
  //         const SizedBox(height: 48), // 간격 축소
  //
  //         // ----------------------------------------------------
  //         // 4. 푸터 영역 (TIME, BUILD BY)
  //         // ----------------------------------------------------
  //         Text("TIME: $currentTime", style: footerStyle),
  //         Text("BUILD BY CAFE.BETA SYSTEM", style: footerStyle),
  //
  //         const SizedBox(height: 4), // 커팅을 위한 최소 여백만 둠
  //       ],
  //     ),
  //   );
  // }
  /// 주문 번호 좌측
  // Widget build(BuildContext context) {
  //   // ----------------------------------------------------
  //   // [스타일 지정]
  //   // ----------------------------------------------------
  //   const TextStyle productOptionStyle = TextStyle(
  //     fontFamily: 'JetBrainsMono',
  //     fontWeight: FontWeight.w400,
  //     fontSize: 24.0,
  //     height: 1.1,
  //     letterSpacing: -0.5,
  //     color: Colors.black,
  //   );
  //
  //   const TextStyle footerStyle = TextStyle(
  //     fontFamily: 'JetBrainsMono',
  //     fontWeight: FontWeight.w400,
  //     fontSize: 20.0,
  //     height: 1.1,
  //     letterSpacing: -0.5,
  //     color: Colors.black,
  //   );
  //
  //   final String currentTime = DateTime.now().toString().substring(0, 19);
  //
  //   return Container(
  //     width: 384, // 58mm 프린터 가로폭 절대 고정
  //     color: Colors.white,
  //     padding: EdgeInsets.zero,
  //     // 🚀 가로 배치(Row)로 변경: [좌측 회전된 텍스트] + [우측 나머지 내용]
  //     child: Row(
  //       crossAxisAlignment: CrossAxisAlignment.start, // 위쪽 라인을 맞춤
  //       children: [
  //         // ----------------------------------------------------
  //         // 1. 좌측 영역: 90도 회전된 주문 번호
  //         // ----------------------------------------------------
  //         Padding(
  //           padding: const EdgeInsets.only(left: 4.0, top: 12.0, right: 16.0),
  //           child: RotatedBox(
  //             quarterTurns: 3, // 3 = 270도 회전 (밑에서 위로 읽는 방향)
  //             child: RichText(
  //               text: TextSpan(
  //                 style: const TextStyle(
  //                   fontFamily: 'JetBrainsMono',
  //                   fontWeight: FontWeight.w700,
  //                   fontSize: 50.0,
  //                   height: 1.0,
  //                   letterSpacing: -1.5,
  //                   color: Colors.black,
  //                 ),
  //                 children: [
  //                   TextSpan(text: orderNo),
  //                   TextSpan(
  //                     text: ".$sequence/$totalSequence",
  //                     style: const TextStyle(fontSize: 50.0, fontWeight: FontWeight.w700), // 서브번호 폰트 크기 비율 조정
  //                   ),
  //                 ],
  //               ),
  //             ),
  //           ),
  //         ),
  //
  //         // ----------------------------------------------------
  //         // 2. 우측 영역: QR, PRODUCT, OPTION, FOOTER
  //         // ----------------------------------------------------
  //         // Expanded를 사용하여 남은 가로 영역을 모두 차지하게 함
  //         Expanded(
  //           child: Column(
  //             mainAxisSize: MainAxisSize.min,
  //             crossAxisAlignment: CrossAxisAlignment.start, // 왼쪽 정렬
  //             children: [
  //               const SizedBox(height: 8), // 최상단 여백
  //
  //               // [QR 영역]
  //               SizedBox(
  //                 width: 120.0,
  //                 height: 120.0,
  //                 child: QrImageView(
  //                   data: qrData,
  //                   size: 120.0,
  //                   padding: EdgeInsets.zero,
  //                   gapless: false,
  //                 ),
  //               ),
  //
  //               const SizedBox(height: 24), // 간격 유지
  //
  //               // [PRODUCT 영역]
  //               Text("[PRODUCT]", style: productOptionStyle.copyWith(fontWeight: FontWeight.w700)),
  //               Text(
  //                 menus.isNotEmpty ? menus.first : "ICED BananaMilkCoffee",
  //                 style: productOptionStyle.copyWith(fontSize: 20),
  //               ),
  //               Text("Version: 0.94.0506.02", style: productOptionStyle.copyWith(fontSize: 20)),
  //
  //               const SizedBox(height: 24),
  //
  //               // [OPTION 영역]
  //               Text("[OPTION]", style: productOptionStyle.copyWith(fontWeight: FontWeight.w700)),
  //               Text("- BEAN: BETA_DARK_ROAST", style: productOptionStyle.copyWith(fontSize: 20)),
  //               Text("- MILK: 100ml", style: productOptionStyle.copyWith(fontSize: 20)),
  //               Text("- BANANA_SYRUP: 10ml", style: productOptionStyle.copyWith(fontSize: 20)),
  //               Text("- TEMP: ICED (DEFAULT)", style: productOptionStyle.copyWith(fontSize: 20)),
  //
  //               const SizedBox(height: 48),
  //
  //               // [푸터 영역] - 텍스트 변경 적용
  //               Text("ORDER TIME: $currentTime", style: footerStyle),
  //               Text("BUILD BY CAFE.BETA OS", style: footerStyle),
  //
  //               const SizedBox(height: 4), // 커팅용 최소 여백
  //             ],
  //           ),
  //         ),
  //       ],
  //     ),
  //   );
  // }
/// 주문 번호 좌측 + 점선
  Widget build(BuildContext context) {
    // ----------------------------------------------------
    // [스타일 지정]
    // ----------------------------------------------------
    const TextStyle productOptionStyle = TextStyle(
      fontFamily: 'JetBrainsMono',
      fontWeight: FontWeight.w400,
      fontSize: 24.0,
      height: 1.1,
      letterSpacing: -0.5,
      color: Colors.black,
    );

    const TextStyle footerStyle = TextStyle(
      fontFamily: 'JetBrainsMono',
      fontWeight: FontWeight.w400,
      fontSize: 20.0,
      height: 1.1,
      letterSpacing: -0.5,
      color: Colors.black,
    );

    final String currentTime = DateTime.now().toString().substring(0, 19);

    List<Widget> optionWidgets = [];
    optionWidgets.add(Text("[OPTION]", style: productOptionStyle.copyWith(fontWeight: FontWeight.w700)));

    String currentMenuEN = menus.isNotEmpty ? menus.first : "";
    MenuRecipe? recipe = RecipeManager().getRecipe(currentMenuEN);

    // 1. 레시피 시트 기반 옵션 추가
    if (recipe != null) {
      bool isValid(String v) => v.isNotEmpty && v != "-";

      if (isValid(recipe.espresso)) {
        // 🚀 [수정] 원두량이 존재하면 (DOSE: 19g) 텍스트를 생성하여 에스프레소 문자열 뒤에 붙임
        String doseInfo = isValid(recipe.beanWeight) ? " (Bean: ${recipe.beanWeight}g)" : "";
        optionWidgets.add(Text("- ESP: ${recipe.espresso}ml$doseInfo", style: productOptionStyle.copyWith(fontSize: 20)));
      }
      if (isValid(recipe.waterIce)) {
        optionWidgets.add(Text("- WATER (ICE): ${recipe.waterIce}ml", style: productOptionStyle.copyWith(fontSize: 20)));
      }
      if (isValid(recipe.waterHot)) {
        optionWidgets.add(Text("- WATER (HOT): ${recipe.waterHot}ml", style: productOptionStyle.copyWith(fontSize: 20)));
      }
      if (isValid(recipe.milk)) {
        optionWidgets.add(Text("- MILK: ${recipe.milk}ml", style: productOptionStyle.copyWith(fontSize: 20)));
      }
    }

    // 2. QR 데이터 기반 동적 디스펜서 옵션 추가 (예: Banana_Syrup:20|1004,pkey:21)
    String dispenserData = qrData.split('|').first; // "Banana_Syrup:20" 또는 "N:0"
    if (dispenserData.isNotEmpty && dispenserData != "N:0") {
      var parts = dispenserData.split(':');
      if (parts.length == 2) {
        String extName = parts[0].replaceAll("_", " "); // "Banana_Syrup" -> "Banana Syrup"
        String extAmount = parts[1];
        optionWidgets.add(Text("- ${extName.toUpperCase()}: ${extAmount}g", style: productOptionStyle.copyWith(fontSize: 20)));
      }
    }

    // 만약 옵션이 하나도 없다면 기본값 표시
    if (optionWidgets.length == 1) {
      optionWidgets.add(Text("- STANDARD RECIPE", style: productOptionStyle.copyWith(fontSize: 20)));
    }

    return Container(
      width: 384, // 58mm 프린터 가로폭 절대 고정
      color: Colors.white,
      padding: EdgeInsets.zero,
      // 🚀 IntrinsicHeight: 좌/우 자식 중 더 긴 쪽의 높이에 맞춰 줍니다. (점선이 끝까지 내려가게 함)
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch, // 세로로 꽉 채움
          children: [
            // ----------------------------------------------------
            // 1. 좌측 영역: 90도 회전된 주문 번호
            // ----------------------------------------------------
            Container(
              padding: const EdgeInsets.only(left: 4.0, top: 12.0, right: 12.0),
              alignment: Alignment.topCenter, // 글씨가 상단부터 시작되도록 고정
              child: RotatedBox(
                quarterTurns: 3, // 270도 회전
                child: RichText(
                  text: TextSpan(
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontWeight: FontWeight.w700,
                      fontSize: 50.0,
                      height: 1.0,
                      letterSpacing: -1.5,
                      color: Colors.black,
                    ),
                    children: [
                      TextSpan(text: orderNo),
                      TextSpan(
                        text: ".$sequence/$totalSequence",
                        style: const TextStyle(fontSize: 50.0, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // ----------------------------------------------------
            // 🚀 2. 중간 영역: 수직 점선 (CustomPaint)
            // ----------------------------------------------------
            CustomPaint(
              painter: DashedLinePainter(),
              size: const Size(2, double.infinity), // 두께 2px, 높이는 부모(IntrinsicHeight)를 따라감
            ),

            const SizedBox(width: 12), // 점선과 우측 콘텐츠 사이의 여백

            // ----------------------------------------------------
            // 3. 우측 영역: QR, PRODUCT, OPTION, FOOTER
            // ----------------------------------------------------
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),

                  // [QR 영역]
                  SizedBox(
                    width: 120.0,
                    height: 120.0,
                    child: QrImageView(
                      data: qrData,
                      size: 120.0,
                      padding: EdgeInsets.zero,
                      gapless: false,
                    ),
                  ),

                  const SizedBox(height: 24),

                  // [PRODUCT 영역]
                  Text("[PRODUCT]", style: productOptionStyle.copyWith(fontWeight: FontWeight.w700)),
                  Text(
                    menus.isNotEmpty ? menus.first : "ICED BananaMilkCoffee",
                    style: productOptionStyle.copyWith(fontSize: 20),
                  ),
                  Text("Version: 0.94.0506.02", style: productOptionStyle.copyWith(fontSize: 20)),

                  const SizedBox(height: 24),

                  // [OPTION 영역]
                  // Text("[OPTION]", style: productOptionStyle.copyWith(fontWeight: FontWeight.w700)),
                  // Text("- BEAN: BETA_DARK_ROAST", style: productOptionStyle.copyWith(fontSize: 20)),
                  // Text("- MILK: 100ml", style: productOptionStyle.copyWith(fontSize: 20)),
                  // Text("- BANANA_SYRUP: 10ml", style: productOptionStyle.copyWith(fontSize: 20)),
                  // Text("- TEMP: ICED (DEFAULT)", style: productOptionStyle.copyWith(fontSize: 20)),

                  ...optionWidgets,

                  const SizedBox(height: 48),

                  // [푸터 영역]
                  Text("ORDER TIME: $currentTime", style: footerStyle),
                  Text("BUILD BY CAFE.BETA OS", style: footerStyle),

                  const SizedBox(height: 8), // 커팅용 여백
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class DashedLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    double dashHeight = 5.0; // 점선 하나의 길이
    double dashSpace = 4.0;  // 점선 사이의 간격
    double startY = 0.0;

    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.0; // 점선의 두께

    while (startY < size.height) {
      canvas.drawLine(
        Offset(0, startY),
        Offset(0, startY + dashHeight),
        paint,
      );
      startY += dashHeight + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}