// バックアップ manifest.json のモデル（タスク 01a20bfe・データ層）。
//
// WHY: ZIP の先頭で「何のアプリの、どのスキーマの、何件入りか」を宣言しておくと、
// 将来スキーマを変えたときに旧アプリが誤って復元するのを防げる。未知キーは
// 無視して前方互換を保ち、型不一致だけは明示エラーにして黙った取り違えを避ける。
import 'backup_format_exception.dart';

/// manifest.json の内容。
class BackupManifest {
  const BackupManifest({
    required this.appVersion,
    required this.exportedAt,
    required this.recordCount,
    required this.imageCount,
    this.templateCount = 0,
    this.format = backupFormat,
    this.schemaVersion = currentSchemaVersion,
  });

  /// このアプリのバックアップであることを示す固定文字列。
  /// manifest.json の `format` がこの値と一致しない ZIP は取り込まない。
  static const String backupFormat = 'scoreyomipm.backup';

  /// 現在のスキーマ版。読み込み時にこれより大きい版は拒否する。
  static const int currentSchemaVersion = 1;

  final String format;
  final int schemaVersion;
  final String appVersion;
  final DateTime exportedAt;
  final int recordCount;
  final int imageCount;

  /// 同梱したメモテンプレートの件数。
  ///
  /// WHY 省略可能（既定 0）か: テンプレート同梱より前に作られた ZIP には
  /// このキーが無い。無いだけで復元を失敗させるのは過剰なので、欠落は 0 として
  /// 読み、records/画像の復元はそのまま続行する（前方互換）。
  final int templateCount;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'format': format,
    'schemaVersion': schemaVersion,
    'appVersion': appVersion,
    // WHY: 端末のタイムゾーンに依存しない形（UTC ISO8601）で保存する。
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'recordCount': recordCount,
    'imageCount': imageCount,
    'templateCount': templateCount,
  };

  /// JSON から読む。未知キーは読み捨て、型不一致は [BackupFormatException]。
  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    return BackupManifest(
      format: _readString(json, 'format'),
      schemaVersion: _readInt(json, 'schemaVersion'),
      appVersion: _readString(json, 'appVersion'),
      exportedAt: _readDateTime(json, 'exportedAt'),
      recordCount: _readInt(json, 'recordCount'),
      imageCount: _readInt(json, 'imageCount'),
      templateCount: _readIntOr(json, 'templateCount', 0),
    );
  }

  /// 省略可能な整数を読む（欠落は [fallback]、型不一致は明確に拒否）。
  static int _readIntOr(Map<String, dynamic> json, String key, int fallback) {
    if (!json.containsKey(key)) {
      return fallback;
    }
    return _readInt(json, key);
  }

  static String _readString(Map<String, dynamic> json, String key) {
    final Object? value = json[key];
    if (value is String) {
      return value;
    }
    throw BackupFormatException('manifest.json の $key が文字列ではありません');
  }

  static int _readInt(Map<String, dynamic> json, String key) {
    final Object? value = json[key];
    // WHY: JSON の数値は int で来る想定。double を黙って切り捨てると件数が
    // ずれたまま復元してしまうため、int 以外は明確に拒否する。
    if (value is int) {
      return value;
    }
    throw BackupFormatException('manifest.json の $key が整数ではありません');
  }

  static DateTime _readDateTime(Map<String, dynamic> json, String key) {
    final String text = _readString(json, key);
    final DateTime? parsed = DateTime.tryParse(text);
    if (parsed == null) {
      throw BackupFormatException('manifest.json の $key が日時として解釈できません');
    }
    return parsed;
  }
}
