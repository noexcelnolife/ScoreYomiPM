// 一括取り込みの抽象（タスク 01a20bfe・データ層）。
//
// WHY: 復元は「既存を残すマージ」と「全部入れ替える全置換」の 2 方式があり、
// UI は保存先の実装（ファイル/メモリ/将来のクラウド）を知る必要がない。既存の
// PlayRecordRepository（1 件ずつの CRUD）は変更せず、一括操作だけを別抽象にする
// ことで、通常の保存経路に影響を与えない。
import 'dart:typed_data';

import 'play_record.dart';

/// 一括取り込みの結果。
class BulkImportResult {
  const BulkImportResult({
    required this.imported,
    required this.skipped,
    required this.missingImages,
  });

  /// 実際に書き込んだ件数。
  final int imported;

  /// 既存 id と重複したため書き込まなかった件数（マージ時のみ非 0）。
  final int skipped;

  /// 元画像が見つからず、画像なしとして書き込んだ件数。
  final int missingImages;
}

/// レコードをまとめて書き込む口。
abstract class PlayRecordBulkWriter {
  /// [records] をまとめて保存する。
  ///
  /// [replaceAll] が true のときは既存レコードと既存画像を削除してから書き込む。
  /// false のときは同じ id の既存レコードを残し、新規のみ追加する（冪等）。
  ///
  /// [imageBytesById] はレコード id と原画像バイト列の対応。ZIP 復元時に
  /// 一時ファイルを経由せずバイト列をそのまま渡すため、Web でも動作する。
  Future<BulkImportResult> importAll(
    List<PlayRecord> records, {
    required bool replaceAll,
    Map<String, Uint8List?>? imageBytesById,
  });
}
