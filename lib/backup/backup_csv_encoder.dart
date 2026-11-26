// バックアップ CSV のエンコーダ（タスク 01a20bfe・データ層）。
//
// WHY: ZIP は再インポート用、CSV は表計算ソフトでの閲覧用という別用途を持つ。
// CSV は Excel で開く前提なので、BOM 付き UTF-8・CRLF・RFC4180 の引用規則に
// 従う。列順は仕様の並び（実施日時 → 記録元）を固定し、後から増えた列
// （メモ）は末尾にのみ追加する。
import '../data/play_record.dart';

/// PlayRecord を CSV 文字列へ変換する。
class BackupCsvEncoder {
  const BackupCsvEncoder();

  /// ヘッダ行（BOM を含まない本体）。
  ///
  /// WHY メモを末尾に足すか: 既存列の位置を動かすと、この CSV を読み込む
  /// 表計算のシートや手元のスクリプトが黙って壊れる。追加は必ず末尾に置く。
  static const String headerLine =
      '実施日時,曲名,難易度,レベル,スコア,COOL,GREAT,GOOD,BAD,MAX COMBO,クリアメダル,機種,状態,記録元,メモ';

  static const String _bom = '\uFEFF';
  static const String _crlf = '\r\n';

  /// 全レコードを 1 本の CSV 文字列にする（末尾にも CRLF を付ける）。
  String encode(List<PlayRecord> records) {
    final StringBuffer buffer = StringBuffer(_bom)
      ..write(headerLine)
      ..write(_crlf);
    for (final PlayRecord record in records) {
      buffer
        ..write(_row(record))
        ..write(_crlf);
    }
    return buffer.toString();
  }

  String _row(PlayRecord record) {
    final List<String> cells = <String>[
      _formatDateTime(record.playedAt),
      _escape(record.songName ?? ''),
      _difficultyLabel(record.difficulty),
      _intCell(record.level),
      _intCell(record.score),
      _intCell(record.cool),
      _intCell(record.great),
      _intCell(record.good),
      _intCell(record.bad),
      _intCell(record.maxCombo),
      _escape(record.clearMedal ?? ''),
      _escape(record.machine ?? ''),
      _statusLabel(record.status),
      _sourceLabel(record.source),
      _escape(record.memo ?? ''),
    ];
    return cells.join(',');
  }

  String _intCell(int? value) => value?.toString() ?? '';

  /// 表示は端末のローカル時刻に合わせる（保存値は UTC でも利用者は現地時刻で読む）。
  String _formatDateTime(DateTime value) {
    final DateTime local = value.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  /// 難易度は画面表示と同じ「enum 名の大文字」に揃える（LIGHT/NORMAL/HYPER/EX）。
  String _difficultyLabel(GameDifficulty? difficulty) =>
      difficulty?.name.toUpperCase() ?? '';

  String _statusLabel(PlayRecordStatus status) {
    return switch (status) {
      PlayRecordStatus.pending => '未確定',
      PlayRecordStatus.confirmed => '確定',
    };
  }

  String _sourceLabel(PlayRecordSource source) {
    return switch (source) {
      PlayRecordSource.playshare => 'プレーシェア',
    };
  }

  /// RFC4180: カンマ・引用符・改行を含む値は全体を `"` で囲み、`"` は `""` にする。
  String _escape(String value) {
    final bool needsQuote =
        value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r');
    if (!needsQuote) {
      return value;
    }
    return '"${value.replaceAll('"', '""')}"';
  }
}
