class CafeOrder {
  final String orderId;    // CSV의 0번 컬럼 (OrderId)
  final String menuTitle;  // CSV의 6번 컬럼 (menuTitle)

  CafeOrder({
    required this.orderId,
    required this.menuTitle,
  });

  // 주문번호가 "2.4E+16"처럼 깨져 보일 때 숫자만 추출해서 뒷 4자리만 반환하는 함수
  String get shortOrderId {
    // 소수점 앞부분만 가져오고 숫자 이외의 문자 제거
    String cleanId = orderId.split('.')[0].replaceAll(RegExp(r'[^0-9]'), '');

    if (cleanId.isEmpty) return "0000";

    // 번호가 길면 마지막 4자리만, 짧으면 전체 반환
    return cleanId.length > 4
        ? cleanId.substring(cleanId.length - 4)
        : cleanId;
  }
}