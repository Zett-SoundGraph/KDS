enum OrderStatus { pending, ready, pickedUp }

class OrderItem {
  final String orderNo;
  final String menuName;
  OrderStatus status;

  OrderItem({
    required this.orderNo,
    required this.menuName,
    this.status = OrderStatus.pending,
  });
}