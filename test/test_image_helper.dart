// テスト用の最小画像（3x2 PNG・アスペクト比 1.5）生成ヘルパー。
//
// WHY: リポジトリの画像保存や Image.file のデコードを伴うウィジェットテスト
// （FR-4 の保存フロー・未確定レコード一覧）では、実在する有効な画像ファイル
// が必要。1x1 PNG（アスペクト 1.0）はどの入力種別にも非代表的であり、Phase 5
// の分類規則（アスペクト <1.45 → arcadeResultFrame）により意図しない ac_v1
// 経路に流れる可能性がある。プレーシェア代表の 1.5 アスペクト（3x2 px）を
// 使用することで、分類の混乱を避ける。実データ回帰ガード
// （input_classification_realdata_test.dart）が classification の authoritative
// ソース。

import 'dart:convert';
import 'dart:io';

/// 3x2 白ピクセルの PNG（プレーシェア相当・アスペクト比 1.5）。
const String _png3x2Base64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAAAAAC4HznGAAAADUlEQVQBCAD3/wD///8A////npp6SAAAAABJRU5ErkJggg==';

/// テスト用の有効な PNG をテンポラリに作成して返す。
///
/// ファイル名はタイムスタンプで一意化する（テスト終了後の削除は省略し、
/// OS のテンポラリ掃除に任せる。PoC のテストで許容）。
File createTestImageFile() {
  final Directory tempDir = Directory.systemTemp;
  final File file = File(
    '${tempDir.path}${Platform.pathSeparator}'
    'scoreyomipm-test-${DateTime.now().microsecondsSinceEpoch}.png',
  )..writeAsBytesSync(base64Decode(_png3x2Base64));
  return file;
}
