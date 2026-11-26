//
// ac_v1 ラベル実位置診断ツール（一回限りの分析・コミット対象外でもよい）。
//
// 使い方:
//   dart run tool/diag_ac_labels.dart
//
// 入力: test/fixtures/ocr/ac_hc_batch_results.json
// 出力: stdout（SCORE/COOL/GREAT/GOOD/BAD/COMBO/BEST を含む全要素の
//        正規化中心座標 + 数値風テキストの近傍要素）
//
// WHY 暫定 canonical ゲートにラベルが存在しないため: OCR-Core の WIP 座標
// と実測データの乖離を確認し、真のラベル位置をデータから特定するための
// 診断ツール。アンカー/マッチャ設計の前に行う事実確認。
import 'dart:convert';
import 'dart:io';

const String _fixturePath = 'test/fixtures/ocr/ac_hc_batch_results.json';

void main() {
  final fixture =
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final results = fixture['results'] as List<dynamic>;
  final wanted = Platform.environment['AC_DUMP_FILES'] ?? '';
  for (final r in results) {
    final rec = r as Map<String, dynamic>;
    final file = rec['file'] as String;
    if (wanted.isNotEmpty &&
        !wanted.split(',').any((f) => file.contains(f.trim()))) {
      continue;
    }
    final w = (rec['imageWidth'] as num).toDouble();
    final h = (rec['imageHeight'] as num).toDouble();
    final lines = <String>[];
    for (final e in (rec['elements'] as List<dynamic>)) {
      final map = e as Map<String, dynamic>;
      final text = (map['text'] as String).trim();
      final bb = map['boundingBox'] as Map<String, dynamic>;
      final cx = (((bb['l'] as num) + (bb['r'] as num)) / 2 / w)
          .toStringAsFixed(3);
      final cy = (((bb['t'] as num) + (bb['b'] as num)) / 2 / h)
          .toStringAsFixed(3);
      final conf = (map['confidence'] as num?)?.toStringAsFixed(2) ?? '-';
      lines.add('$text @($cx,$cy) conf=$conf');
    }
    final aspect = (w / h).toStringAsFixed(2);
    stdout.writeln(
      '== $file ${w.toInt()}x${h.toInt()} aspect=$aspect elements=${lines.length}',
    );
    for (final line in lines) {
      stdout.writeln('   $line');
    }
  }
}
