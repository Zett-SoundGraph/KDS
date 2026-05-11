enum OrderStatus { pending, ready, pickedUp }

// 개별 메뉴 항목 (음료 1잔 단위)
class SubItem {
  final String menuName;
  OrderStatus status;

  double progress = 0.0;
  List<String> logs = [];
  bool isExtracting = false;
  bool isError = false;
  String? errorCode;
  String currentStage = "Pending";

  SubItem({
    required this.menuName,
    this.status = OrderStatus.pending,
  }) {
    logs = ["🚀 Pending..."];
  }
}

// 주문 카드 전체 정보
class OrderItem {
  final String orderNo;     // 101, 102 등 순번
  final String rawOrderId;  // CSV의 긴 ID (그룹화 기준)
  final String? nickname;
  final List<SubItem> items; // 한 주문 내의 메뉴 리스트

  int drinkCount = 0;
  int foodCount = 0;
  int bottleCount = 0;

  OrderItem({
    required this.orderNo,
    required this.rawOrderId,
    required this.items,
    this.nickname,
  });

  // 모든 메뉴가 ready 상태인지 확인하는 Getter
  bool get isAllReady => items.every((item) => item.status == OrderStatus.ready);

  String get displayName => (nickname != null && nickname!.isNotEmpty)
      ? nickname!
      : "NO.$orderNo";
}