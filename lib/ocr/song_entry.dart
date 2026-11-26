// ST-6 楽曲エントリ（リポジトリ抽象化）
//
// spec.md §10: 収録曲DB リポジトリ抽象化。SongEntry は bundledSeed /
// downloadedMain / localAdditional の全ソースで共通の不変データモデル。
// normalizedKey は song_title_normalizer.normalizeSongTitle(title) から導出。
//
// 譜面別レベル (levels) は Map<String,int> で LIGHT/NORMAL/HYPER/EX の4キーを想定。
// UPPER 譜面は未決のためキーを強制せず、存在すれば格納・無ければ省略（拡張余地確保）。
// 譜面別総ノーツ数 (notesCounts) も同規約。totalNotes は JSON キーではなく
// computed getter として合成する（リード最終裁定 01a2030b）: notesCounts 非空なら
// max(notesCounts.values)、空なら legacy 値（main_v1 由来・fromJson 読み戻し）。
// FR-6 段階 B VR-1 の上限チェック契約（S > totalNotes）を維持する。
// spec.md §5.3/§2.2 と整合。

library;

import 'song_title_normalizer.dart';

/// 楽曲エントリ（不変データクラス）。
///
/// 各ソース（bundledSeed/downloadedMain/localAdditional）からの JSON パース結果を
/// 保持。normalizedKey は title から正規化して導出。
class SongEntry {
  /// 楽曲ID（DB主キー、ソース間で一意であるべき）。
  final String id;

  /// 元表記の曲名。
  final String title;

  /// 正規化済み曲名（照合キー）。
  final String normalizedKey;

  /// ジャンル名（任意）。
  final String? genre;

  /// アーティスト名（任意）。
  final String? artist;

  /// 譜面別レベルマップ。キー: 譜面名（"LIGHT"/"NORMAL"/"HYPER"/"EX" / 将来 "UPPER"）、値: レベル。
  /// UPPER 譜面は未決のためキーを強制しない。
  final Map<String, int> levels;

  /// legacy の総ノーツ数（単一値・任意・private）。
  ///
  /// WHY private フィールド（リード裁定 01a2030b）: main_v1.json の 135 曲は
  /// totalNotes のみで notesCounts を持たず、このキーを捨てると 135 曲分の
  /// ノーツデータが喪失する。外部には [totalNotes] computed getter 経由でのみ
  /// 見せる（直接参照させず、合成規則を一元化する）。
  final int? _legacyTotalNotes;

  /// 譜面別総ノーツ数マップ（整合性検証 VR-1/VR-3 用）。
  ///
  /// WHY 単一 totalNotes からの置換: seed_v2 では難易度ごとに総ノーツ数を
  /// 収集する（docs/notes_count_collection_2026-11-22.md）。Harmonia のように
  /// LIGHT と EX の両方が判明している曲は単一値では表現できないため、
  /// 難易度キーのマップで保持する。未収集難易度はキー自体を省略する
  /// （null 埋めしない・seed_v2 規約）。
  final Map<String, int> notesCounts;

  /// 収録バージョン（任意）。
  final String? version;

  const SongEntry({
    required this.id,
    required this.title,
    required this.normalizedKey,
    this.genre,
    this.artist,
    this.levels = const {},
    this._legacyTotalNotes,
    this.notesCounts = const {},
    this.version,
  });

  /// FR-6 段階 B VR-1 上限チェック用の契約値（読み取り専用の合成値）。
  ///
  /// WHY computed getter（リード裁定 01a2030b）: seed_v2.json は totalNotes キーを
  /// 持たないため、notesCounts 非空なら max(notesCounts.values)（＝最大難易度の
  /// ノーツ数）を合成して返す。再生難易度不明の VR-1 では最大値を境界にするのが
  /// 安全側（小さい値を境界にすると EX 演奏の正記録を誤検知する）。
  /// notesCounts 不在の legacy 曲（main_v1 の 135 曲）は JSON から読み戻した
  /// legacy 値をそのまま返す。両方無しは null＝VR-1 skip 扱い。
  /// getter 名を totalNotes のままにして App-UI 承認済み契約参照を維持する。
  int? get totalNotes {
    if (notesCounts.isNotEmpty) {
      var max = notesCounts.values.first;
      for (final v in notesCounts.values) {
        if (v > max) {
          max = v;
        }
      }
      return max;
    }
    return _legacyTotalNotes;
  }

  /// 指定難易度の総ノーツ数（未収集・未知キーは null）。
  ///
  /// WHY `Option<int>` 風の null 安全アクセサ: FR-6 VR-1/VR-3 は
  /// 「再生難易度の総ノーツ数」が得られたときのみ検証し、null（データ不在）
  /// では検証を skip する規約のため、欠落を null で区別して返す。
  int? notesCountFor(String difficulty) => notesCounts[difficulty];

  /// JSON マップから SongEntry を構築。
  ///
  /// 必須フィールド: id, title。normalizedKey は省略時 title から自動導出。
  /// schema バリデーションに失敗すると [ArgumentError] を投げる。
  factory SongEntry.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final title = json['title'] as String?;
    if (id == null || id.isEmpty) {
      throw ArgumentError('SongEntry: id は必須です');
    }
    if (title == null || title.isEmpty) {
      throw ArgumentError('SongEntry: title は必須です');
    }

    final normalizedKey =
        json['normalizedKey'] as String? ?? normalizeSongTitle(title);
    if (normalizedKey.isEmpty) {
      throw ArgumentError('SongEntry: normalizedKey が空です');
    }

    final levelsJson = json['levels'] as Map<String, dynamic>?;
    final levels = <String, int>{};
    if (levelsJson != null) {
      levelsJson.forEach((k, v) {
        levels[k] = v is int ? v : int.tryParse(v.toString()) ?? 0;
      });
    }

    return SongEntry(
      id: id,
      title: title,
      normalizedKey: normalizedKey,
      genre: json['genre'] as String?,
      artist: json['artist'] as String?,
      levels: levels,
      legacyTotalNotes: _parseLegacyTotalNotes(json['totalNotes']),
      notesCounts: _parseNotesCounts(json['notesCounts']),
      version: json['version'] as String?,
    );
  }

  /// legacy totalNotes を寛容にパースする（正数のみ受理）。
  ///
  /// WHY main_v1.json の 135 曲のノーツデータ救済（リード裁定 01a2030b）:
  /// int または数字文字列を受理する。0 以下・非パース値は契約上あり得ないため
  /// null＝データ不在に倒す（VR-1 が 0 を受理して常時通過する防御）。
  static int? _parseLegacyTotalNotes(Object? raw) {
    final notes = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    return notes != null && notes > 0 ? notes : null;
  }

  /// notesCounts マップを寛容にパースする。
  ///
  /// WHY 値は正数のみ受理: VR-1 は notesCount >= count の比較のため、
  /// 0 を受理すると検証が常に通過してしまう。不正値（0 以下・非パース）は
  /// キーごと省略＝データ不在（FR-6 では skip 扱い）に倒す。キーは
  /// levels と同様に強制しない（UPPER 拡張余地）。
  static Map<String, int> _parseNotesCounts(Object? notesCountsJson) {
    final notesCounts = <String, int>{};
    if (notesCountsJson is Map<String, dynamic>) {
      notesCountsJson.forEach((key, value) {
        final notes = value is int ? value : int.tryParse(value.toString());
        if (notes != null && notes > 0) {
          notesCounts[key] = notes;
        }
      });
    }
    return notesCounts;
  }

  /// JSON マップへ変換（asset JSON 再書き出し・キャッシュ用）。
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'normalizedKey': normalizedKey,
      if (genre != null) 'genre': genre,
      if (artist != null) 'artist': artist,
      if (levels.isNotEmpty) 'levels': levels,
      // WHY 条件付き出力（リード裁定 01a2030b）: notesCounts が空で legacy 値が
      // あるとき（＝main_v1 由来の旧形状）のみ totalNotes を出力し往復無損失を
      // 保つ。seed_v2 由来（notesCounts 非空）の曲に旧キーを広げない。
      if (notesCounts.isEmpty && _legacyTotalNotes != null)
        'totalNotes': _legacyTotalNotes,
      if (notesCounts.isNotEmpty) 'notesCounts': notesCounts,
      if (version != null) 'version': version,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SongEntry &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          title == other.title &&
          normalizedKey == other.normalizedKey;

  @override
  int get hashCode => Object.hash(id, title, normalizedKey);

  @override
  String toString() =>
      'SongEntry(id: $id, title: $title, normalizedKey: $normalizedKey)';
}

/// 曲名辞書照合用の軽量ビュー（SongTitleMatcher 用）。
///
/// SongRepository のエントリを [SongTitleMatcher] の契約（titles / originalTitle /
/// contains）に適合させるアダプタ。Matcher は変更なしで利用可能。
class SongDictionaryView {
  final Map<String, String> _normalizedToOriginal = {};
  final List<String> _titles = [];

  SongDictionaryView(List<SongEntry> entries) {
    for (final entry in entries) {
      _normalizedToOriginal[entry.normalizedKey] = entry.title;
      if (!_titles.contains(entry.normalizedKey)) {
        _titles.add(entry.normalizedKey);
      }
    }
  }

  List<String> get titles => List.unmodifiable(_titles);

  String? originalTitle(String normalizedTitle) =>
      _normalizedToOriginal[normalizedTitle];

  bool contains(String title) => _normalizedToOriginal.containsKey(title);

  int get length => _titles.length;
}
