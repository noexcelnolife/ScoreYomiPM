// テスト用の最小画像（3x2 PNG・アスペクト比 1.5）生成ヘルパー。
//
// WHY: リポジトリの画像保存や画像ウィジェットのデコードを伴うウィジェットテスト
// （FR-4 の保存フロー・未確定レコード一覧）では、実在する有効な画像ファイル
// が必要。1x1 PNG（アスペクト 1.0）はどの入力種別にも非代表的であり、Phase 5
// の分類規則（アスペクト <1.45 → arcadeResultFrame）により意図しない ac_v1
// 経路に流れる可能性がある。プレーシェア代表の 1.5 アスペクト（3x2 px）を
// 使用することで、分類の混乱を避ける。実データ回帰ガード
// （input_classification_realdata_test.dart）が classification の authoritative
// ソース。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 3x2 単色の PNG（プレーシェア相当・アスペクト比 1.5）。
///
/// WHY(手組みの PNG をやめたか): 圧縮ストリームを自前で並べると、zlib ヘッダを
/// 落としたまま通ってしまう。GDI+ などは寛容に読むが Flutter のデコーダは
/// 拒否し、画像を出すテストだけが「復号失敗」になる。実際に画像処理系で
/// 生成した PNG を貼る。
const String _png3x2Base64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8'
    'YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAARSURBVBhXYzghJ/cfhhmQOQCbFQwT6CQ/xAAAAABJRU5E'
    'rkJggg==';

/// テスト用の有効な PNG のバイト列。
///
/// WHY(ファイルではなくバイト列か): 画像の保存先は BlobStore に閉じており、
/// リポジトリはバイト列を受け取る。端末のディスクに依存しないテストは、
/// そのまま Web 実装でも通る。
Uint8List createTestImageBytes() => base64Decode(_png3x2Base64);

/// テスト用の有効な PNG をテンポラリに作成して返す。
///
/// ファイル名はタイムスタンプで一意化する（テスト終了後の削除は省略し、
/// OS のテンポラリ掃除に任せる。PoC のテストで許容）。
File createTestImageFile() {
  return createTempImageFileFromBytes(
    base64Decode(_png3x2Base64),
    'scoreyomipm-test-${DateTime.now().microsecondsSinceEpoch}.png',
  );
}

/// 任意のバイト列を一時ファイルに書き出して返す。
///
/// WHY(実ファイルが要る場面があるか): OCR パイプラインは今のところ実ファイルを
/// 読む（[P3] のバイト入力化は未実施）。バイト列しか持っていない画像を流したい
/// ときは、ここで一時ファイルにして渡す。
File createTempImageFileFromBytes(Uint8List bytes, String name) {
  final Directory tempDir = Directory.systemTemp;
  final File file = File(
    '${tempDir.path}${Platform.pathSeparator}$name',
  )..writeAsBytesSync(bytes);
  return file;
}
