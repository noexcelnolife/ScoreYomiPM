"""【参考・未使用】JIS X 0213 の文字集合（第 1〜第 4 水準＋付属の記号類）。

`subset_fonts.py` はこのモジュールを **import しない**。文字集合は元フォントの
cmap をそのまま使う（詳細は `subset_fonts.py` の docstring）。

使えなくなった理由:
  ここでは Python 標準の `euc_jis_2004` コーデック（JIS X 0213:2004 の公式対応表）
  から逆算している。EUC-JIS-2004 では
    1 バイト目 0xA1〜0xFE × 2 バイト目 0xA1〜0xFE が第 1〜第 3 水準、
    先頭に 0x8F を付けた 3 バイト列が第 4 水準、半角カタカナは 0x8E + 0xA1〜0xDF。
  ところがこのコーデックは **NEC/IBM 拡張と記号ブロックを符号化できない**。
  そのため `㊗ ㊙ ㈪〜㉃ ㊑〜㊰ ㎅〜㎳ ⑴〜⒇ ⒜〜⒵ ⓪ ㍿ ㌅ 髙 﨎 鶴 ￠ ￡ ¥ ∑` など
  元フォント（BIZ UDPGothic）が持っていた 230 字が漏れた。

  実害: 配布 DB の曲名 `HOTな夜の㊙ドリンク` の `㊙` が描けない。
  `cp932` を足しても `㊙` は埋まらないため、コーデックの追加では解決しない。

残している理由: 文字集合を外から与える方式を再検討するとき、どこで何が漏れるかを
再現できるようにするため。参照専用。
"""

from __future__ import annotations

_LEAD_BYTES = range(0xA1, 0xFF)
_TRAIL_BYTES = range(0xA1, 0xFF)
_PLANE_2_PREFIX = b"\x8f"
_HALFWIDTH_LEAD = 0x8E
_HALFWIDTH_BYTES = range(0xA1, 0xE0)
_ASCII_BYTES = range(0x20, 0x7F)

# アプリが実際に使うが JIS X 0213 に入っていない文字。
# lib/**/*.dart と assets/**/*.json の全文走査で見つかったものだけを載せる。
#
# 「节」(U+8282) は当初このリストに含める指示だったが、載せていない。
# 理由は 2 つで、(1) BIZ UDPGothic に字形が無い（どの部分集合にも入れられない）、
# (2) 出現箇所が lib/ocr/ac_row_estimator.dart のコメント 1 行だけで、
# 画面に描画されない。字形が無い文字を指定しても何も起きないため。
EXTRA_CHARACTERS = "—≤≥离"


def _decode_or_nothing(payload: bytes) -> str:
    try:
        return payload.decode("euc_jis_2004")
    except UnicodeDecodeError:
        return ""


def _two_and_three_byte_characters() -> set[str]:
    characters: set[str] = set()
    for lead in _LEAD_BYTES:
        for trail in _TRAIL_BYTES:
            characters.update(_decode_or_nothing(bytes([lead, trail])))
            characters.update(_decode_or_nothing(_PLANE_2_PREFIX + bytes([lead, trail])))
    return characters


def _halfwidth_katakana_characters() -> set[str]:
    characters: set[str] = set()
    for trail in _HALFWIDTH_BYTES:
        characters.update(_decode_or_nothing(bytes([_HALFWIDTH_LEAD, trail])))
    return characters


def jisx0213_characters() -> set[int]:
    """JIS X 0213 の文字集合をコードポイントの集合として返す。"""
    characters: set[str] = _two_and_three_byte_characters()
    characters |= _halfwidth_katakana_characters()
    # ASCII は JIS X 0201 の GL として JIS X 0213 に含まれる。
    characters.update(chr(code) for code in _ASCII_BYTES)
    characters.update(EXTRA_CHARACTERS)
    return {ord(character) for character in characters}
