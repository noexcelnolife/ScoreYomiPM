"""同梱する日本語フォント（BIZ UDPGothic）から、描画に使わないデータだけを落とす。

背景:
  同梱フォントは 2 本で 9.3MB あり、Web 版の初回取得量の大部分を占めていた。
  削れるのは「字形そのもの」ではなく、Skia が使わないヒンティングと、
  Flutter に組版の無い縦組み用データである。

設計（重要・差し戻しの経緯）:
  当初は「JIS X 0213 の範囲に絞る」方針で `euc_jis_2004` から文字集合を逆算して
  いたが、このコーデックは NEC/IBM 拡張と記号ブロックを符号化できず、元フォントに
  あった 230 字（`髙` `㊙` `㍿` `⑴` `㎅` など）を落とした。配布 DB に実在する曲名
  `HOTな夜の㊙ドリンク` が豆腐になったため、方針を変えた。

  以降の文字集合は **元フォントの cmap そのもの**とする。フォントが持っている字は
  1 つも落とさない。つまりこの処理は cmap について恒等写像で、削減はすべて
  ヒンティング・縦組み・メタデータから得る。

使い方:
  py -3 tool/fonts/subset_fonts.py
  py -3 tool/fonts/subset_fonts.py --source-dir ../.local/fonts-src
  py -3 tool/fonts/subset_fonts.py --output-dir %TEMP%\\out

  --source-dir 省略時は assets/fonts を読む。cmap を落とさない処理なので、
  処理済みのファイルを入力にしても出力は同じ大きさになる（冪等）。

終了コード:
  0 正常 / 1 検証で字形の欠落を検出（バグ。落とし方を疑うこと）
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FONT_DIRECTORY = REPOSITORY_ROOT / "assets" / "fonts"
FONT_FILE_TEMPLATE = "BIZUDPGothic-{weight}.ttf"
FONT_WEIGHTS = ("Regular", "Bold")

# アプリが描画しうる文字を探す場所。ここにある文字が 1 つでも欠けたら失敗させる。
TEXT_SOURCE_PATTERNS = ("lib/**/*.dart", "assets/**/*.json")

# 配布している曲 DB。リポジトリには含めない（.gitignore の /db/）が、手元にあれば
# 曲名・ジャンル名・アーティスト名がフォントで描けるかを検証する。
# WHY(ここも見るか): 差し戻しの直接原因がこれだった。`lib/` と `assets/` だけを
# 見ていたため、DB にしか出てこない `㊙` の欠落を検出できなかった。
DISTRIBUTED_DB_PATH = REPOSITORY_ROOT / "db" / "popn_hc_main_v1.json"

# 同梱フォントが持つべき最低文字数。差し戻し時点の元フォントの実測値。
# これを下回ったら「cmap を落とす変更が混ざった」と判断して失敗させる。
MINIMUM_CODEPOINTS = 11_741

# 縦組み専用の機能。Flutter に縦書きの組版は無いので、これらの機能が参照する
# 代替字形（.vert など）ごと落とせる。
VERTICAL_LAYOUT_FEATURES = frozenset({"vert", "vrt2", "vkrn", "vpal", "vhal", "valt"})

# vert を消した以上、縦組みの寸法表（vhea/vmtx）と縦原点（vorg）は参照されない。
VERTICAL_METRIC_TABLES = ("vhea", "vmtx", "vorg")


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
    options.drop_tables = list(options.drop_tables) + ["meta"] + list(
        VERTICAL_METRIC_TABLES
    )
    return options


def characters_used_in_sources() -> dict[int, str]:
    """アプリが描画しうる文字を、コードポイント → 出現元 で返す。"""
    used: dict[int, str] = {}
    for pattern in TEXT_SOURCE_PATTERNS:
        for path in sorted(REPOSITORY_ROOT.glob(pattern)):
            if path.is_file():
                collect_characters(path, used)
    if DISTRIBUTED_DB_PATH.is_file():
        collect_characters(DISTRIBUTED_DB_PATH, used)
    return used


def collect_characters(path: Path, used: dict[int, str]) -> None:
    text = path.read_text(encoding="utf-8", errors="replace")
    try:
        label = str(path.relative_to(REPOSITORY_ROOT))
    except ValueError:
        label = str(path)
    for character in set(text):
        codepoint = ord(character)
        if codepoint < 0x20 or codepoint == 0x7F:
            # 改行・タブなどの制御文字は字形を持たない。数えても意味がない。
            continue
        used.setdefault(codepoint, label)


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
    parser = argparse.ArgumentParser(
        description="BIZ UDPGothic から描画に不要なデータを落とす（cmap は保持）"
    )
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
    parser.add_argument(
        "--baseline-dir",
        type=Path,
        default=None,
        help="文字集合の基準にする無加工の TTF。省略時は --source-dir と同じ",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    options = build_subset_options()
    baseline_dir = arguments.baseline_dir or arguments.source_dir

    print(f"元のフォント: {arguments.source_dir}")
    print(f"基準のフォント: {baseline_dir}")
    print(f"書き出し先: {arguments.output_dir}")

    before_total = 0
    after_total = 0
    results: list[tuple[str, Path, Path]] = []
    for weight in FONT_WEIGHTS:
        source_path = arguments.source_dir / FONT_FILE_TEMPLATE.format(weight=weight)
        output_path = arguments.output_dir / FONT_FILE_TEMPLATE.format(weight=weight)
        before = source_path.stat().st_size
        after = subset_one(source_path, output_path, options)
        before_total += before
        after_total += after
        results.append((weight, source_path, output_path))
        print(f"  {weight}: {before:,} B -> {after:,} B ({after - before:+,} B)")

    print(f"合計: {before_total:,} B -> {after_total:,} B ({after_total - before_total:+,} B)")
    return verify(results, baseline_dir)


def subset_one(source_path: Path, output_path: Path, options: subset.Options) -> int:
    """source の cmap をそのまま残して書き出す。落とすのは字形以外だけ。"""
    font = subset.load_font(str(source_path), options)
    try:
        subsetter = subset.Subsetter(options=options)
        # WHY(元の cmap をそのまま渡すか): ここを外部の文字集合にすると、
        # 集合の決め方を間違えた瞬間に実在の曲名が豆腐になる。フォントが持って
        # いる字を落とさない、が唯一の安全な既定。
        subsetter.populate(unicodes=sorted(font.getBestCmap().keys()))
        subsetter.subset(font)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        subset.save_font(font, str(output_path), options)
    finally:
        font.close()
    return output_path.stat().st_size


def verify(results: list[tuple[str, Path, Path]], baseline_dir: Path) -> int:
    """書き出したフォントが、元フォントとアプリの文字をすべて持っているか確かめる。"""
    used = set(characters_used_in_sources())
    print(f"検証対象のテキスト: {len(used):,} 種の文字")

    failed = False
    for weight, source_path, output_path in results:
        output_coverage = coverage_of(output_path)
        source_coverage = coverage_of(source_path)
        baseline_path = baseline_dir / FONT_FILE_TEMPLATE.format(weight=weight)
        baseline_coverage = (
            coverage_of(baseline_path) if baseline_path.is_file() else source_coverage
        )

        # 1) この実行で字形を落としていないこと。
        lost_now = sorted(source_coverage - output_coverage)
        if lost_now:
            failed = True
            print(
                f"欠落: {output_path.name} が入力から字形を落としている:\n  "
                + format_codepoints(lost_now),
                file=sys.stderr,
            )

        # 2) 基準フォントの字形を完全に包含していること（差集合が空）。
        lost_against_baseline = sorted(baseline_coverage - output_coverage)
        if lost_against_baseline:
            failed = True
            print(
                f"欠落: {output_path.name} に基準フォントの "
                f"{len(lost_against_baseline)} 字が無い:\n  "
                + format_codepoints(lost_against_baseline[:80]),
                file=sys.stderr,
            )

        # 3) 総数が減っていないこと（1・2 が空なら自明だが、意図を残す）。
        if len(output_coverage) < MINIMUM_CODEPOINTS:
            failed = True
            print(
                f"欠落: {output_path.name} の文字数 {len(output_coverage):,} が "
                f"下限 {MINIMUM_CODEPOINTS:,} を下回る",
                file=sys.stderr,
            )

        # 4) アプリと配布 DB が使う文字を持っていること。
        #    元フォントに字形が無い文字は、どの部分集合にも入れられない。Web は
        #    フォールバック（Noto）、Android は端末フォントで描かれるので失敗にしない。
        absent_from_baseline = used - baseline_coverage
        lost_used = sorted(used - output_coverage - absent_from_baseline)
        if lost_used:
            failed = True
            print(
                f"欠落: {output_path.name} にアプリが使う文字が無い:\n  "
                + format_codepoints(lost_used),
                file=sys.stderr,
            )
        else:
            print(
                f"  {weight}: cmap {len(output_coverage):,} 字"
                f"（基準 {len(baseline_coverage):,} 字を完全包含）"
            )
        if absent_from_baseline:
            print(
                f"参考: {weight} の元フォントに字形が無い文字（フォールバックで描画）: "
                + format_codepoints(sorted(absent_from_baseline))
            )

    if failed:
        return 1
    print("検証: 元フォントの cmap を完全包含し、アプリの文字もすべて収録済み")
    return 0


if __name__ == "__main__":
    sys.exit(main())
