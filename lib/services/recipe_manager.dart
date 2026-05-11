// services/recipe_manager.dart

import 'package:flutter/services.dart' show rootBundle;
import 'package:csv/csv.dart';
import '../models/menu_recipe.dart'; // 🚀 방금 만든 모델 클래스를 불러옵니다.

class RecipeManager {
  static final RecipeManager _instance = RecipeManager._internal();
  factory RecipeManager() => _instance;
  RecipeManager._internal();

  // 영어 메뉴명을 Key로 사용하는 레시피 맵
  final Map<String, MenuRecipe> _recipeMap = {};

  Future<void> loadRecipeCsv() async {
    try {
      final String rawData = await rootBundle.loadString("assets/data/recipe.csv");
      final normalizedData = rawData.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

      List<List<dynamic>> csvTable = const CsvToListConverter(
        fieldDelimiter: ',',
        eol: '\n',
        shouldParseNumbers: false, // 텍스트로 안전하게 파싱
      ).convert(normalizedData);

      _recipeMap.clear();

      // 첫 번째 줄(헤더) 제외하고 순회
      for (var i = 1; i < csvTable.length; i++) {
        final row = csvTable[i];
        if (row.length < 10) continue; // 데이터가 부족한 행은 무시

        String menuNameEN = row[3].toString().trim(); // D열: 메뉴명(EN)

        // 데이터가 비어있거나 "-" 인 것을 원본 그대로 가져옴
        _recipeMap[menuNameEN] = MenuRecipe(
          menuNameEN: menuNameEN,
          beanWeight: row[5].toString().trim(),
          espresso: row[6].toString().trim(), // F열: 에스프레소
          waterIce: row[7].toString().trim(), // G열: 물(ICE)
          waterHot: row[8].toString().trim(), // H열: 물(HOT)
          milk: row[10].toString().trim(),     // J열: 우유
        );
      }
      print("✅ [RecipeManager] 레시피 데이터 ${_recipeMap.length}개 로드 완료!");
    } catch (e) {
      print("❌ [RecipeManager] 레시피 CSV 로드 실패: $e");
    }
  }

  // 메뉴명으로 레시피 반환
  MenuRecipe? getRecipe(String menuNameEN) {
    String searchKey = menuNameEN.trim(); // 앱에서 넘긴 이름

    // 🚀 [KDS_DEBUG] 태그로 통일! 로그캣 검색창에 KDS_DEBUG 만 치세요!
    print("[KDS_DEBUG] --------------------------------------------------");
    print("[KDS_DEBUG] 🔍 검색 요청 메뉴: '$searchKey'");
    print("[KDS_DEBUG] 📋 시트에 저장된 키: ${_recipeMap.keys.toList()}");

    if (_recipeMap.containsKey(searchKey)) {
      print("[KDS_DEBUG] ✅ 매칭 성공!");
      print("[KDS_DEBUG] --------------------------------------------------");
      return _recipeMap[searchKey];
    } else {
      print("[KDS_DEBUG] ❌ 매칭 실패!");
      print("[KDS_DEBUG] --------------------------------------------------");
      return null;
    }
  }
}