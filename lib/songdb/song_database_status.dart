// 収録曲辞書（song DB）の状態照会モデル（案A: 常設ステータス・spec §10）。
//
// WHY: これまで更新結果は呼び出し側のその場限りの通知に使われて捨てられ、
// 再起動後に「どの辞書が何曲入っているか」「最後の更新が成功したか」を
// 知る手段が無かった。表示に必要な値だけを持つ不変モデルとして切り出す。

/// 辞書操作の種類（最終操作の記録に使う）。
enum SongDbOperationKind {
  /// 配信 URL からのメイン DB 更新。
  update,

  /// ローカル追加 DB の取り込み。
  importAdditional,
}

/// 最終操作の結果。
///
/// WHY: 成功/失敗の 2 値では「URL 未設定によるスキップ」を失敗として表示して
/// しまい、ユーザーに原因の分からない失敗に見えるため 3 値で持つ。
enum SongDbOperationOutcome {
  /// 成功（適用した・または既に最新だった）。
  success,

  /// 失敗（取得・保存・取り込みのいずれかが失敗）。
  failure,

  /// 実行していない（配信 URL 未設定など、前提が揃っていない）。
  skipped,
}

/// 辞書ソース 1 つ分の状態。
class SongDbSourceStatus {
  const SongDbSourceStatus({
    required this.exists,
    this.songCount,
    this.dbVersion,
    this.updatedAt,
  });

  /// ファイルが存在するか。
  final bool exists;

  /// 収録曲数。ファイルが壊れていて数えられない場合は null。
  final int? songCount;

  /// DB バージョン（メイン DB のみ）。
  final int? dbVersion;

  /// ファイルの最終更新時刻。
  final DateTime? updatedAt;
}

/// 最後に実行した辞書操作の記録。
class SongDbLastOperation {
  const SongDbLastOperation({
    required this.kind,
    required this.outcome,
    required this.at,
    this.message,
    this.songCount,
    this.dbVersion,
    this.sourceFileName,
  });

  /// 操作の種類。
  final SongDbOperationKind kind;

  /// 操作の結果（成功・失敗・スキップ）。
  final SongDbOperationOutcome outcome;

  /// 実行時刻。
  final DateTime at;

  /// 失敗・スキップの理由（例: 'HTTP 404'）。成功時は null。
  final String? message;

  /// 対象となった収録曲数（実際に取得できた場合のみ）。
  final int? songCount;

  /// 適用後の DB バージョン（update のみ・import は null）。
  final int? dbVersion;

  /// 取り込み元ファイル名（import 時のみ・basename）。
  final String? sourceFileName;

  /// 設定ファイルへ保存する形。
  ///
  /// WHY: 時刻はタイムゾーン情報を持たない epoch ミリ秒で保存する。
  /// ローカル時刻の ISO 8601 文字列にすると時差が落ち、往復で別時刻になる。
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'kind': kind.name,
      'outcome': outcome.name,
      'at': at.millisecondsSinceEpoch,
      'message': message,
      'songCount': songCount,
      'dbVersion': dbVersion,
      'sourceFileName': sourceFileName,
    };
  }

  /// 設定ファイルから読み戻す。
  ///
  /// WHY: 記録は表示用の補助情報であり、壊れた値で画面を落とさないため
  /// 解釈できない場合は null（＝記録なし）を返す。例外は投げない。
  static SongDbLastOperation? tryParse(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? kindValue = json['kind'];
    final Object? outcomeValue = json['outcome'];
    final Object? atValue = json['at'];
    if (kindValue is! String || outcomeValue is! String || atValue is! num) {
      return null;
    }
    final SongDbOperationKind? kind = _parseKind(kindValue);
    final SongDbOperationOutcome? outcome = _parseOutcome(outcomeValue);
    if (kind == null || outcome == null) {
      return null;
    }
    return SongDbLastOperation(
      kind: kind,
      outcome: outcome,
      at: DateTime.fromMillisecondsSinceEpoch(atValue.toInt()),
      message: json['message'] is String ? json['message'] as String : null,
      songCount: json['songCount'] is int ? json['songCount'] as int : null,
      dbVersion: json['dbVersion'] is int ? json['dbVersion'] as int : null,
      sourceFileName: json['sourceFileName'] is String
          ? json['sourceFileName'] as String
          : null,
    );
  }

  static SongDbOperationKind? _parseKind(String name) {
    for (final SongDbOperationKind kind in SongDbOperationKind.values) {
      if (kind.name == name) {
        return kind;
      }
    }
    return null;
  }

  static SongDbOperationOutcome? _parseOutcome(String name) {
    for (final SongDbOperationOutcome outcome
        in SongDbOperationOutcome.values) {
      if (outcome.name == name) {
        return outcome;
      }
    }
    return null;
  }
}

/// 辞書全体の状態（ステータス表示用）。
class SongDatabaseStatus {
  const SongDatabaseStatus({
    required this.distributionUrl,
    required this.main,
    required this.additional,
    this.lastOperation,
  });

  /// 設定済みの配信 URL（未設定は空文字）。
  final String distributionUrl;

  /// メイン DB の状態。
  final SongDbSourceStatus main;

  /// 追加 DB の状態。
  final SongDbSourceStatus additional;

  /// 最後に実行した操作（未実行なら null）。
  final SongDbLastOperation? lastOperation;
}
