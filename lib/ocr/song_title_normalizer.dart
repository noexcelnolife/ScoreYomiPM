// ST-5 曲名正規化
//
// 曲名OCR結果を辞書照合用に正規化する。
//  spec.md §5.3 ST-5 に整合: 全角半角・記号/空白除去・大文字小文字畳み込み
//
// 正規化ルール:
//   - 全角英数字 → 半角英数字（ａ-ｚ→a-z, Ａ-Ｚ→A-Z, ０-９→0-9）
//   - 全角記号 → 半角記号（｡→., ､→, ･→· 等）
//   - 空白・記号を除去（スペース、タブ、・, ♪, ♥, ★, ☆, など）
//   - 大文字小文字を畳み込み（toLowerCase）
//   - カタカナ/ひらがな/漢字は保持（辞書照合で利用）

library;

/// 曲名を正規化する
String normalizeSongTitle(String raw) {
  if (raw.isEmpty) return '';

  final buffer = StringBuffer();
  for (final rune in raw.runes) {
    var ch = rune;

    // 全角英字 A-Z (U+FF21-U+FF3A) → 半角 (U+0041-U+005A)
    if (ch >= 0xFF21 && ch <= 0xFF3A) {
      ch -= 0xFEE0;
    }
    // 全角英字 a-z (U+FF41-U+FF5A) → 半角 (U+0061-U+007A)
    else if (ch >= 0xFF41 && ch <= 0xFF5A) {
      ch -= 0xFEE0;
    }
    // 全角数字 0-9 (U+FF10-U+FF19) → 半角 (U+0030-U+0039)
    else if (ch >= 0xFF10 && ch <= 0xFF19) {
      ch -= 0xFEE0;
    }

    final c = String.fromCharCode(ch);

    // 空白・制御文字は除去
    if (c.isEmpty || c.codeUnitAt(0) <= 0x20) continue;

    // 除去対象記号
    final removed = <int>[
      0x30FB, // ・ カタカナ中黒点
      0x266A, // ♪ 音符
      0x2665, // ♥ ハート
      0x2605, // ★ 黒星
      0x2606, // ☆ 白星
      0x25CF, // ● 黒丸
      0x25CB, // ○ 白丸
      0x3000, // 全角スペース
      0xFF0C, // ， 全角コンマ
      0xFF1B, // ； 全角セミコロン
      0xFF1F, // ？ 全角疑問符
      0xFF01, // ！ 全角感嘆符
      0x21, // ! 半角感嘆符（全角 ！ 除去と対称にする。WHY: OCR が付与する半角記号も照合時に無効化）
      0x301C, // ～ 全角チルダ
      0x2014, // — ダッシュ
      0x2013, // – エンダッシュ
      0x3001, // 、 読点
      0x3002, // 。 句点
      0x3008, // 〈 左山括弧
      0x3009, // 〉 右山括弧
      0x300A, // 《 二重左山括弧
      0x300B, // 》 二重右山括弧
      0x3014, // 〖 左黒丸括弧
      0x3015, // 〗 右黒丸括弧
      0x3016, // 〖 左黒 Lenticular
      0x3017, // 〗 右黒 Lenticular
    ];
    if (removed.contains(c.codeUnitAt(0))) continue;

    buffer.writeCharCode(ch);
  }

  return buffer.toString().toLowerCase();
}
