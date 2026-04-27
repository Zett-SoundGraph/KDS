import 'order_item.dart';

class ManufacturingQueueItem {
  final String machineIp;
  final String productKey;
  final String orderNo;
  final SubItem subItem; // UI 상태 업데이트를 위해 참조 유지
  final OrderItem order;

  ManufacturingQueueItem({
    required this.machineIp,
    required this.productKey,
    required this.orderNo,
    required this.subItem,
    required this.order,
  });
}