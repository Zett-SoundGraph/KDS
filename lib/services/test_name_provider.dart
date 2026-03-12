import 'dart:math';

class TestNameProvider {
  // 1. 임시 이름 리스트 (20명)
  static final List<String> _namePool = [
    "DK", "Johnny", "JZ", "Dillan", "Wei",
    "Zett", "Connor", "Pascal", "Song", "Hazel",
    "Luke", "Josephine", "Ellie", "Anne", "Melody",
    "Holy", "Heather", "Dom", "Hank", "Harry",
    "Henry", "Justin", 'Kane', "Will"
  ];

  // 현재 사용 가능한 이름들 (셔플된 상태)
  static List<String> _currentAvailableNames = [];

  // 현재 컵 ID와 매칭된 이름 저장소
  static final Map<int, String> _activeAssignments = {};

  /// 컵 ID에 이름을 할당하거나 이미 있다면 반환
  static String getNameForId(int id) {
    // 이미 할당된 이름이 있다면 그대로 반환 (ID 추적 유지)
    if (_activeAssignments.containsKey(id)) {
      return _activeAssignments[id]!;
    }

    // 이름 풀이 비었거나 처음 시작할 때 새로 셔플
    if (_currentAvailableNames.isEmpty) {
      _currentAvailableNames = List.from(_namePool)..shuffle();
      print("🔄 [TEST] 이름 풀을 모두 소진하여 새로 셔플했습니다.");
    }

    // 풀에서 하나를 꺼내 할당
    String assignedName = _currentAvailableNames.removeLast();
    _activeAssignments[id] = assignedName;

    return assignedName;
  }

  /// 컵이 제거되었을 때 할당 해제
  static void releaseId(int id) {
    _activeAssignments.remove(id);
  }
}