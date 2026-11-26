// FR-4 未確定レコードのデータモデル（spec §4.1 の v1 サブセット）。
//
// WHY: v1 では UI・OCR パイプラインが既に生産している値のみを保存対象とし、
// difficulty/genre/clearMedal 導出等は null 許容の将来拡張とする。
// 正規化（レンジ外・不正値→null）は保存時（toPlayRecord）に適用し、
// 不正値を正の値として保存しない（未確定値の null を許す）。

import '../validation/validation_issue.dart';

/// レコードの確定状態。
enum PlayRecordStatus {
  /// 未確定（曲名不確定・画像のみ等）。
  pending,

  /// 確定（曲名を含む記録が揃っている）。
  confirmed,
}

/// レコードの入力源。
enum PlayRecordSource {
  /// プレーシェア画像。
  playshare,
}

/// 譜面難易度（v5 機能 A・ユーザー裁定により 4 種のみ）。
///
/// WHY: PM の難易度体系は LIGHT/NORMAL/HYPER/EX/UPPER の 5 種だが、
/// ユーザー裁定（2026-11-23）により UPPER は難易度ではなく譜面を区別する要素
/// （UPPER 譜面の区別は将来の別フィールドで扱う候補）として difficulty から
/// 除外した。将来のバージョンで UPPER 譜面が出ても difficulty には戻さない。
/// OCR 認識側の将来拡張で enum を足すときも、未知名の読み込みは fromJson の
/// asNameMap 許容で null に落ちるため旧レコードは壊れない。
enum GameDifficulty {
  /// LIGHT。
  light,

  /// NORMAL。
  normal,

  /// HYPER。
  hyper,

  /// EX。
  ex,
}

/// 選択可能な機種リスト（自由文字列だが UI はこの一覧のみ提示）。
///
/// WHY: 正式名称（HC）は商標リスク回避のため UI ラベル・格納値の
/// どちらも使わず「H☆C!!」表記に統一する（ユーザー裁定）。将来の機種追加は
/// このリスト末尾への追記だけ（chip の ValueKey は index ベースで不変）。
/// WHY 末尾固定: 既定機種は「一覧の先頭」で決まる（machine_default_test.dart）ため、
/// 追記は必ず末尾に行う。先頭に入れると既定が変わり、既存の ValueKey もずれる。
const List<String> availableGameVersions = <String>['H☆C!!', livelyMachineName];

/// PC 版 Lively の機種名。
///
/// WHY 定数にするか: Lively のスコア画面写真を取り込む入口（種別選択シートの
/// 「Lively」行）は、行の選択自体が機種を決める。リストの添字や文字列リテラルを
/// 画面側に散らすと、機種名を変えたときに片方だけ古くなる。
const String livelyMachineName = 'Lively';

/// 手入力・OCR 由来の数値を正規化する。
///
/// int・数値文字列を受理し、パース不能・レンジ外は null を返す。
int? normalizeIntValue(Object? raw, {required int min, required int max}) {
  int? value;
  if (raw is num) {
    value = raw.toInt();
  } else if (raw is String) {
    value = int.tryParse(raw.trim());
  }
  if (value == null || value < min || value > max) {
    return null;
  }
  return value;
}

String? _normalizeSongName(String? raw) {
  if (raw == null) {
    return null;
  }
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 保存済みのプレイ記録。
class PlayRecord {
  const PlayRecord({
    required this.id,
    required this.playedAt,
    required this.songName,
    this.songId,
    required this.score,
    required this.cool,
    required this.great,
    required this.good,
    required this.bad,
    required this.maxCombo,
    required this.level,
    this.clearMedal,
    required this.status,
    required this.source,
    required this.resultImagePath,
    this.difficulty,
    this.machine,
  });

  /// ユニークなレコード ID。
  final String id;

  /// 記録日時（v1 は保存時刻で代用・spec §4.1 備考準拠）。
  final DateTime playedAt;

  /// 曲名（不確定は null）。
  final String? songName;

  /// 辞書上の曲 ID（v1 は保存時照合未実装のため常時 null）。
  final String? songId;

  /// スコア（0〜100000・範囲外は保存時に null）。
  final int? score;

  /// COO 判定数（MISS 判定なし・BAD がミス相当）。
  final int? cool;

  /// GRE 判定数。
  final int? great;

  /// GOO 判定数。
  final int? good;

  /// BAD 判定数（PM のミス相当）。
  final int? bad;

  /// 最大コンボ数。
  final int? maxCombo;

  /// 譜面レベル（1〜50）。
  final int? level;

  /// クリアメダル（v1 は未入力・将来テンプレート照合/機械導出）。
  final String? clearMedal;

  /// 譜面難易度（v5・未選択なら null）。
  final GameDifficulty? difficulty;

  /// 機種（v5・availableGameVersions の値または null）。
  final String? machine;

  /// 確定状態。
  final PlayRecordStatus status;

  /// 入力源。
  final PlayRecordSource source;

  /// 原画像の保存先パス（NFR-5 全件保存基本）。
  final String resultImagePath;

  /// 正規化後の曲名から確定状態を導出する（設計書 §1.2 ルール）。
  ///
  /// 曲名が確定していれば confirmed、不確定なら pending。
  static PlayRecordStatus deriveStatus(String? normalizedSongName) {
    return normalizedSongName == null
        ? PlayRecordStatus.pending
        : PlayRecordStatus.confirmed;
  }

  PlayRecord copyWith({
    String? id,
    DateTime? playedAt,
    String? songName,
    String? songId,
    Object? score = _unset,
    Object? cool = _unset,
    Object? great = _unset,
    Object? good = _unset,
    Object? bad = _unset,
    Object? maxCombo = _unset,
    Object? level = _unset,
    String? clearMedal,
    PlayRecordStatus? status,
    PlayRecordSource? source,
    String? resultImagePath,
    GameDifficulty? difficulty,
    String? machine,
  }) {
    return PlayRecord(
      id: id ?? this.id,
      playedAt: playedAt ?? this.playedAt,
      songName: songName ?? this.songName,
      songId: songId ?? this.songId,
      score: score == _unset ? this.score : score as int?,
      cool: cool == _unset ? this.cool : cool as int?,
      great: great == _unset ? this.great : great as int?,
      good: good == _unset ? this.good : good as int?,
      bad: bad == _unset ? this.bad : bad as int?,
      maxCombo: maxCombo == _unset ? this.maxCombo : maxCombo as int?,
      level: level == _unset ? this.level : level as int?,
      clearMedal: clearMedal ?? this.clearMedal,
      difficulty: difficulty ?? this.difficulty,
      machine: machine ?? this.machine,
      status: status ?? this.status,
      source: source ?? this.source,
      resultImagePath: resultImagePath ?? this.resultImagePath,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'playedAt': playedAt.toIso8601String(),
      'songName': songName,
      'songId': songId,
      'score': score,
      'cool': cool,
      'great': great,
      'good': good,
      'bad': bad,
      'maxCombo': maxCombo,
      'level': level,
      'clearMedal': clearMedal,
      'difficulty': difficulty?.name,
      'machine': machine,
      'status': status.name,
      'source': source.name,
      'resultImagePath': resultImagePath,
    };
  }

  /// JSON から復元する。
  ///
  /// WHY: 欠落キー・未知キーを許容し、壊れた列挙値は既定値へ落とす
  /// （スキーマ進化に耐える設計・設計書 §1.1）。
  factory PlayRecord.fromJson(Map<String, dynamic> json) {
    return PlayRecord(
      id: json['id'] as String? ?? '',
      playedAt:
          DateTime.tryParse(json['playedAt'] as String? ?? '') ??
          DateTime.now(),
      songName: json['songName'] as String?,
      songId: json['songId'] as String?,
      score: _readInt(json['score']),
      cool: _readInt(json['cool']),
      great: _readInt(json['great']),
      good: _readInt(json['good']),
      bad: _readInt(json['bad']),
      maxCombo: _readInt(json['maxCombo']),
      level: _readInt(json['level']),
      clearMedal: json['clearMedal'] as String?,
      difficulty: GameDifficulty.values.asNameMap()[json['difficulty']],
      machine: json['machine'] as String?,
      status:
          PlayRecordStatus.values.asNameMap()[json['status']] ??
          PlayRecordStatus.pending,
      source:
          PlayRecordSource.values.asNameMap()[json['source']] ??
          PlayRecordSource.playshare,
      resultImagePath: json['resultImagePath'] as String? ?? '',
    );
  }

  static const Object _unset = Object();

  static int? _readInt(Object? value) {
    return value is int ? value : null;
  }
}

/// 保存前の記録ドラフト（入力値は未正規化のまま受け取る）。
///
/// WHY: FR-3 の手入力欄から生の値（int・数値文字列・null）をそのまま
/// 受けられるようにし、正規化はリポジトリ保存時の [toPlayRecord] で一括適用する。
class PlayRecordDraft {
  const PlayRecordDraft({
    required this.songName,
    this.songId,
    this.score,
    this.cool,
    this.great,
    this.good,
    this.bad,
    this.maxCombo,
    this.level,
    required this.status,
    required this.source,
    this.clearMedal,
    this.difficulty,
    this.machine,
  });

  /// 曲名（trim・空欄は null に正規化される）。
  final String? songName;

  /// 辞書上の曲 ID（v1 は null）。
  final String? songId;

  /// スコア（0〜100000・int または数値文字列）。
  final Object? score;

  /// COO 判定数。
  final Object? cool;

  /// GRE 判定数。
  final Object? great;

  /// GOO 判定数。
  final Object? good;

  /// BAD 判定数。
  final Object? bad;

  /// 最大コンボ数。
  final Object? maxCombo;

  /// 譜面レベル（1〜50・int または数値文字列）。
  final Object? level;

  /// 確定状態（UI は [PlayRecordStatus.deriveStatus] で導出して渡す）。
  final PlayRecordStatus status;

  /// 入力源。
  final PlayRecordSource source;

  /// クリアメダル分類（未設定なら null）。
  final ClearMedalCategory? clearMedal;

  /// 譜面難易度（v5・未選択なら null）。
  final GameDifficulty? difficulty;

  /// 機種（v5・availableGameVersions の値または null）。
  final String? machine;

  /// 正規化済みの [PlayRecord] を生成する。
  PlayRecord toPlayRecord({
    required String id,
    required String resultImagePath,
    DateTime? playedAt,
  }) {
    final String? normalizedSongName = _normalizeSongName(songName);
    return PlayRecord(
      id: id,
      playedAt: playedAt ?? DateTime.now(),
      songName: normalizedSongName,
      songId: songId,
      score: normalizeIntValue(score, min: 0, max: 100000),
      cool: normalizeIntValue(cool, min: 0, max: 999999),
      great: normalizeIntValue(great, min: 0, max: 999999),
      good: normalizeIntValue(good, min: 0, max: 999999),
      bad: normalizeIntValue(bad, min: 0, max: 999999),
      maxCombo: normalizeIntValue(maxCombo, min: 0, max: 999999),
      level: normalizeIntValue(level, min: 1, max: 50),
      status: status,
      source: source,
      clearMedal: clearMedal?.name,
      difficulty: difficulty,
      machine: machine,
      resultImagePath: resultImagePath,
    );
  }
}
