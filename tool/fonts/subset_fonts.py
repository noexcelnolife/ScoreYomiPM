"""同梱する日本語フォント（BIZ UDPGothic）を JIS X 0213 の範囲まで絞り込む。

背景:
  同梱フォントは 2 本で 9.3MB あり、Web 版の初回取得量の大部分を占めていた。
  アプリが表示しうる文字は JIS X 0213 の範囲にほぼ収まるので、それ以外の
  グリフ・ヒンティング・縦組み用の代替字形を落として軽くする。

使い方:
  py -3 tool/fonts/subset_fonts.py
  py -3 tool/fonts/subset_fonts.py --source-dir ../.local/fonts-src
  py -3 tool/fonts/subset_fonts.py --output-dir %TEMP%\\out

  --source-dir 省略時は assets/fonts を読む。すでに絞り込み済みのファイルを
  読んでも結果は同じ大きさになる（冪等）ので、再現確認はそのまま 2 回流せばよい。
  原本を残しておきたい場合は、先に .local/fonts-src などへコピーして
  --source-dir で指すとよい。

終了コード:
  0 正常 / 1 検証で文字の欠落を検出（EXTRA_CHARACTERS に足す必要がある）
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

sys.path.insert(0, str(Path(__file__).resolve().parent))

from jisx0213_charset import jisx0213_characters  # noqa: E402

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FONT_DIRECTORY = REPOSITORY_ROOT / "assets" / "fonts"
FONT_FILE_TEMPLATE = "BIZUDPGothic-{weight}.ttf"
FONT_WEIGHTS = ("Regular", "Bold")

# アプリが描画しうる文字を探す場所。ここにある文字が 1 つでも欠けたら失敗させる。
TEXT_SOURCE_PATTERNS = ("lib/**/*.dart", "assets/**/*.json")

# 縦組み専用の機能。Flutter に縦書きの組版は無いので、これらの機能が参照する
# 代替字形（.vert など）ごと落とせる。
VERTICAL_LAYOUT_FEATURES = frozenset({"vert", "vrt2", "vkrn", "vpal", "vhal", "valt"})


def build_subset_options() -> subset.Options:
    options = subset.Options()
    # WHY(ヒンティングを落とすか): 描画は Skia（Android も Web の CanvasKit も同じ）
    # で、TrueType のヒンティングを使わない。残しても描画結果は変わらず、
    # 2 本で約 1.8MB を無駄に運ぶことになる。
    options.hinting = False
    options.layout_features = [
        feature
        for feature in options.layout_features
        if feature not in VERTICAL_LAYOUT_FEATURES
    ]
    # 同じ入力から同じバイト列を作る（head.modified を現在時刻に書き換えない）。
    options.recalc_timestamp = False
    # OFL の著作権表示・ライセンス文は name テーブルに残す必要がある。
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.name_languages = ["*"]
    # meta テーブルはサブセット非対応で、放置すると毎回警告が出るうえ結局捨てられる。
    # 文字列メタデータだけで描画には関与しないため、明示的に落とす。
    options.drop_tables = list(options.drop_tables) + ["meta"]
    return options


def characters_used_in_sources() -> dict[int, str]:
    """アプリが描画しうる文字を、コードポイント → 出現元ファイル で返す。"""
    used: dict[int, str] = {}
    for pattern in TEXT_SOURCE_PATTERNS:
        for path in sorted(REPOSITORY_ROOT.glob(pattern)):
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for character in set(text):
                codepoint = ord(character)
                if codepoint < 0x20 or codepoint == 0x7F:
                    # 改行・タブなどの制御文字は字形を持たない。数えても意味がない。
                    continue
                used.setdefault(codepoint, str(path.relative_to(REPOSITORY_ROOT)))
    return used


def coverage_of(font_path: Path) -> set[int]:
    """フォントが文字コードとして持っているコードポイントの集合。"""
    font = TTFont(str(font_path), lazy=True)
    try:
        return set(font.getBestCmap())
    finally:
        font.close()


def format_codepoints(codepoints: list[int]) -> str:
    return " ".join(f"U+{codepoint:04X}({chr(codepoint)})" for codepoint in codepoints)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="BIZ UDPGothic を JIS X 0213 まで絞る")
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=DEFAULT_FONT_DIRECTORY,
        help="元の TTF があるディレクトリ（既定: assets/fonts）",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_FONT_DIRECTORY,
        help="書き出し先（既定: assets/fonts）",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    options = build_subset_options()
    character_set = jisx0213_characters()

    print(f"文字集合: JIS X 0213 {len(character_set):,} 文字")
    print(f"元のフォント: {arguments.source_dir}")
    print(f"書き出し先: {arguments.output_dir}")

    before_total = 0
    after_total = 0
    sources: list[Path] = []
    outputs: list[Path] = []
    for weight in FONT_WEIGHTS:
        source_path = arguments.source_dir / FONT_FILE_TEMPLATE.format(weight=weight)
        output_path = arguments.output_dir / FONT_FILE_TEMPLATE.format(weight=weight)
        before = source_path.stat().st_size
        after = subset_one(source_path, output_path, options, character_set)
        before_total += before
        after_total += after
        sources.append(source_path)
        outputs.append(output_path)
        print(f"  {weight}: {before:,} B -> {after:,} B ({after - before:+,} B)")

    print(f"合計: {before_total:,} B -> {after_total:,} B ({after_total - before_total:+,} B)")

    return verify(sources, outputs, character_set)


def subset_one(
    source_path: Path,
    output_path: Path,
    options: subset.Options,
    character_set: set[int],
) -> int:
    font = subset.load_font(str(source_path), options)
    try:
        subsetter = subset.Subsetter(options=options)
        subsetter.populate(unicodes=sorted(character_set))
        subsetter.subset(font)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        subset.save_font(font, str(output_path), options)
    finally:
        font.close()
    return output_path.stat().st_size


def verify(
    outputs: list[Path],
    sources: list[Path],
    character_set: set[int],
) -> int:
    """書き出したフォントが、アプリの文字をすべて持っているか確かめる。"""
    used = set(characters_used_in_sources())

    outside_jisx0213 = sorted(codepoint for codepoint in used if codepoint not in character_set)
    if outside_jisx0213:
        print(
            "参考: JIS X 0213 の外にある文字をソースが使っている:\n  "
            + format_codepoints(outside_jisx0213)
        )

    failed = False
    for source_path, output_path in zip(sources, outputs):
        source_coverage = coverage_of(source_path)
        output_coverage = coverage_of(output_path)
        # 元のフォントに無い文字は、どの部分集合にも入れられない。描画されないので
        # 落とし穴にはならない（Web はフォールバック、Android は端末フォント）。
        unavailable = sorted(used - source_coverage)
        if unavailable:
            print(
                f"参考: {source_path.name} の元フォントに字形が無い文字: "
                + format_codepoints(unavailable)
            )
        lost = sorted(used - output_coverage - set(unavailable))
        if lost:
            failed = True
            print(
                f"欠落: {output_path.name} に次の文字が無い:\n  " + format_codepoints(lost),
                file=sys.stderr,
            )

    if failed:
        print(
            "対処: tool/fonts/jisx0213_charset.py の EXTRA_CHARACTERS に追加してください。",
            file=sys.stderr,
        )
        return 1
    print(f"検証: ソースの文字 {len(used):,} 種はすべて収録済み、または元フォントに字形が無い")
    return 0


if __name__ == "__main__":
    sys.exit(main())
