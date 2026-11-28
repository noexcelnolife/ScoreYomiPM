// 収録曲 DB の取得・更新・ローカル追加 DB 取り込みを担うサービス（spec §10）。
//
// WHY: ディスク・ネットワークへの入出力は UI 層から分離し、抽象
// [SongDatabaseService] を通じて UI に提供する（DIP）。マージ／フォールバック
// （シード・メイン・追加の優先順位統合）は OCR-Core 側の MergedSongRepository
// に完結しており、本サービスは「辞書ファイルをディスクに置く」ことのみを責務とする。
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../platform/blob_store.dart';
import 'song_db_paths.dart';
import 'song_database_status.dart';

export 'song_database_status.dart';

/// 追加 DB として取り込める JSON の上限（5 MB）。
///
/// WHY(5MB か): 追加 DB の実データは 2100 曲で約 1.0 MB。上限は「取り違えた別
/// ファイルを選んだ」場合の暴発防止であり、実データに対して十分な余裕を残す。
/// 選択側（`defaultPickAdditionalFile`）と判定側（本サービス）で同じ値を使う。
const int kMaxAdditionalJsonBytes = 5 * 1024 * 1024;

/// 収録曲 DB 操作の抽象インターフェース（UI はこの抽象のみに依存する）。
abstract class SongDatabaseService {
  /// 設定済みの配信 URL。未設定は空文字。
  Future<String> loadDistributionUrl();

  /// 辞書の現在の状態（各ソースの有無・曲数・最終操作）を返す。
  ///
  /// WHY: 再起動後に「今どの辞書が何曲入っているか」「最後の更新が成功したか」
  /// を表示するための照会 API（案A: 常設ステータス）。読み取りのみで書き込みは
  /// 行わない。
  Future<SongDatabaseStatus> loadStatus();

  /// 配信 URL を設定ファイルへ保存する。
  Future<void> saveDistributionUrl(String url);

  /// 設定済み URL からメイン DB を取得・更新する。
  Future<SongDbUpdateResult> updateFromConfiguredUrl();

  /// 指定 URL からメイン DB を取得・更新する（URL 未設定時は skippedNoUrl）。
  Future<SongDbUpdateResult> updateFromUrl(String url);

  /// ローカル追加 DB の JSON バイト列を取り込む。
  ///
  /// [fileName] は取り込み元のファイル名（記録・表示用）。パス文字列は
  /// Web では開けないため、境界からパスを排除しバイト列＋名前で渡す。
  /// [declaredLength] は選択時点で分かっている元ファイルのサイズ
  /// （上限超過を読み込み前に弾くための申告値。省略時は [bytes] の長さで判定）。
  Future<SongImportResult> importAdditionalJson(
    Uint8List bytes, {
    required String fileName,
    int? declaredLength,
  });
}

/// [SongDatabaseService.updateFromUrl] / [updateFromConfiguredUrl] の結果状態。
enum SongDbUpdateStatus {
  /// 配信 URL 未設定のため何もしなかった（UI 側が SnackBar で案内・P-5 2026-11-23）。
  skippedNoUrl,

  /// サーバーの新しい DB を保存した（更新適用）。
  applied,

  /// ローカルが既に最新のため保存しなかった。
  upToDate,

  /// 取得・検証・保存のいずれかで失敗した。
  failed,
}

/// メイン DB 更新の結果。
///
/// [dbVersion] / [songCount] は applied・upToDate 時に、[message] は failed 時に
/// 設定される。
class SongDbUpdateResult {
  const SongDbUpdateResult({
    required this.status,
    this.dbVersion,
    this.songCount,
    this.message,
  });

  /// 結果状態。
  final SongDbUpdateStatus status;

  /// 適用・確認済みの DB バージョン。
  final int? dbVersion;

  /// DB 内の収録曲数。
  final int? songCount;

  /// 失敗時の表示用メッセージ。
  final String? message;
}

/// ローカル追加 DB 取り込みの結果。
class SongImportResult {
  const SongImportResult({required this.success, this.songCount, this.message});

  /// 取り込み成功か。
  final bool success;

  /// 取り込んだ収録曲数（成功時）。
  final int? songCount;

  /// 失敗時の表示用メッセージ。
  final String? message;
}

/// [SongDatabaseService] の実装（ファイルシステム・IndexedDB 共通）。
///
/// [blobStore] 経由で保存先にアクセスする。io プラットフォームでは
/// `IoBlobStore`、Web では `IdbBlobStore` を渡す。サービス実装は 1 つに
/// 統一し、`UnsupportedSongDatabaseService` は廃止された。
///
/// 保存先契約（キーは `/` 区切りの相対パス）:
/// - メイン DB: `songs/main_v1.json`
/// - 追加 DB: `songs/additional_v1.json`
/// - 設定: `songs/settings.json`
/// - 配信 URL: `songs/distribution_url.json`
class FileSongDatabaseService implements SongDatabaseService {
  /// [blobStore] は `IoBlobStore`（io）または `IdbBlobStore`（web）。
  final BlobStore blobStore;

  /// HTTP クライアントの生成関数。
  ///
  /// WHY: 注入可能にし、テストでは MockClient を使う（DIP）。
  final http.Client Function() _httpClientFactory;

  /// 現在時刻の取得関数。
  ///
  /// WHY: 最終操作の記録時刻をテストで固定値と厳密に比較するため注入する。
  final DateTime Function() _clock;

  FileSongDatabaseService({
    required this.blobStore,
    this._httpClientFactory = http.Client.new,
    this._clock = DateTime.now,
  });

  @override
  Future<String> loadDistributionUrl() async {
    final bytes = await blobStore.read(SongDbPaths.settingsRelativePath);
    if (bytes == null) return '';
    final content = utf8.decode(bytes);
    // WHY: 壊れた設定ファイルは空として扱う（次回保存で正常な形に直る）。
    try {
      final dynamic decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) {
        final Object? value = decoded['distributionUrl'];
        return value is String ? value : '';
      }
    } on FormatException catch (_) {
      // 壊れた JSON は無視
    }
    return content;
  }

  @override
  Future<SongDatabaseStatus> loadStatus() async {
    // WHY: loadStatus はホーム画面の起動時に呼ばれる表示専用 API のため、
    // 設定が読めなくても画面を落とさず「未設定・記録なし」として返す。
    final Map<String, dynamic> settings = await _readSettingsForStatus();
    final Object? url = settings['distributionUrl'];
    return SongDatabaseStatus(
      distributionUrl: url is String ? url : '',
      main: await _readSourceStatus(SongDbPaths.mainDbRelativePath, withDbVersion: true),
      additional: await _readSourceStatus(
        SongDbPaths.additionalDbRelativePath,
        withDbVersion: false,
      ),
      lastOperation: SongDbLastOperation.tryParse(settings['lastOperation']),
    );
  }

  @override
  Future<void> saveDistributionUrl(String url) async {
    // WHY: 最終操作の記録（lastOperation）など既存キーを消さないため、
    // 丸ごと上書きではなく読み込み→マージ→書き込みで保存する。
    final bytes = await blobStore.read(SongDbPaths.settingsRelativePath);
    final Map<String, dynamic> settings = bytes != null
        ? (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)
        : <String, dynamic>{};
    settings['distributionUrl'] = url;
    await blobStore.write(
      SongDbPaths.settingsRelativePath,
      utf8.encode(jsonEncode(settings)),
    );
  }

  @override
  Future<SongDbUpdateResult> updateFromConfiguredUrl() async {
    final String url = await loadDistributionUrl();
    return updateFromUrl(url);
  }

  @override
  Future<SongDbUpdateResult> updateFromUrl(String url) async {
    final _UpdateOutcome outcome = await _performUpdate(url);
    // WHY: 記録は呼び出し側に任せずサービス内で完結させる（呼び出し側が
    // 記録を忘れるとステータス表示が実態と食い違うため）。
    await _recordLastOperation(_toUpdateOperation(outcome));
    return outcome.result;
  }

  @override
  Future<SongImportResult> importAdditionalJson(
    Uint8List bytes, {
    required String fileName,
    int? declaredLength,
  }) async {
    final SongImportResult result = await _performImport(
      bytes,
      fileName: fileName,
      declaredLength: declaredLength,
    );
    await _recordLastOperation(
      SongDbLastOperation(
        kind: SongDbOperationKind.importAdditional,
        outcome: result.success
            ? SongDbOperationOutcome.success
            : SongDbOperationOutcome.failure,
        at: _clock(),
        // WHY: message は失敗・スキップの理由のみを持つ規約のため、
        // 成功時の補足は保存しない。
        message: result.success ? null : result.message,
        songCount: result.songCount,
        // WHY: dbVersion はメイン DB のエンベロープにのみ存在する概念で、
        // 追加 DB の取り込みでは意味を持たない。
        sourceFileName: fileName,
      ),
    );
    return result;
  }

  /// 配信 URL からの取得・保存を実行する。
  ///
  /// WHY: 記録に残す「サーバー側の収録曲数」は upToDate（ローカルが新しい）
  /// 場合にも意味があるため、公開結果を変えずに内部で持ち回る。
  Future<_UpdateOutcome> _performUpdate(String url) async {
    if (url.isEmpty) {
      // WHY: URL 未設定はバンドル内蔵辞書（シード）に任せる（失敗ではない）。
      // 案内表示は呼び出し側の役割（song_db_section が SnackBar で通知・P-5）。
      return const _UpdateOutcome(
        result: SongDbUpdateResult(status: SongDbUpdateStatus.skippedNoUrl),
      );
    }
    try {
      final Map<String, dynamic> envelope = await _fetchEnvelope(url);
      final int serverDbVersion = _readDbVersion(envelope);
      final int remoteSongCount = (envelope['songs'] as List<dynamic>).length;
      final existing = await blobStore.read(SongDbPaths.mainDbRelativePath);
      if (existing != null) {
        final int localDbVersion = await _readLocalDbVersion(existing);
        if (localDbVersion >= serverDbVersion) {
          return _UpdateOutcome(
            result: SongDbUpdateResult(
              status: SongDbUpdateStatus.upToDate,
              dbVersion: localDbVersion,
            ),
            remoteSongCount: remoteSongCount,
            dbVersion: localDbVersion,
          );
        }
      }
      // WHY: ローカル DB が無い場合は dbVersion の値に関係なく常時保存する
      // （初回起動時ダウンロードフロー・設計確定事項）。
      final int songCount = await _saveMainDb(envelope);
      return _UpdateOutcome(
        result: SongDbUpdateResult(
          status: SongDbUpdateStatus.applied,
          dbVersion: serverDbVersion,
          songCount: songCount,
        ),
        remoteSongCount: songCount,
        dbVersion: serverDbVersion,
      );
    } catch (error) {
      return _UpdateOutcome(
        result: SongDbUpdateResult(
          status: SongDbUpdateStatus.failed,
          message: '辞書の取得に失敗しました: $error',
        ),
      );
    }
  }

  /// ローカル追加 DB を取り込む（記録用の情報は戻り値から取る）。
  ///
  /// [bytes] はファイル選択で得たバイト列（P3 相当：Web 対応のためパス文字列を
  /// 境界から排除）。[fileName] は表示・記録用のファイル名。
  /// [declaredLength] は選択時点で分かっている元ファイルのサイズ。
  ///
  /// WHY([declaredLength] を持つか): 上限超過を**読み込む前に**弾きたいが、
  /// 取り込みの合否メッセージはサービスが一元管理する。選択側はサイズだけ申告し、
  /// 判定とメッセージはここに寄せる（メッセージの二重管理を避ける）。
  Future<SongImportResult> _performImport(
    Uint8List bytes, {
    required String fileName,
    int? declaredLength,
  }) async {
    final int sizeInBytes = declaredLength ?? bytes.lengthInBytes;
    if (sizeInBytes > kMaxAdditionalJsonBytes) {
      return const SongImportResult(
        success: false,
        message: 'ファイルサイズが 5MB を超えています。',
      );
    }

    // WHY: 空ファイルは早期に検出し、JSON パースをスキップする。
    if (bytes.isEmpty) {
      return const SongImportResult(
        success: false,
        message: '選択されたファイルが空です。',
      );
    }

    try {
      final String content = utf8.decode(bytes);
      final dynamic decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic> || decoded['songs'] is! List) {
        return const SongImportResult(
          success: false,
          message: '"songs" 配列を含む JSON ファイルを選択してください。',
        );
      }

      // WHY: 拡張子の検証だけ残す（パス文字列ではなく fileName のみを使用）。
      final String name = fileName.toLowerCase();
      if (!name.endsWith('.json')) {
        return const SongImportResult(
          success: false,
          message: 'JSON ファイル（.json）を選択してください。',
        );
      }

      await blobStore.write(
        SongDbPaths.additionalDbRelativePath,
        utf8.encode(jsonEncode(decoded)),
      );
      final List<dynamic> songs = decoded['songs'] as List<dynamic>;
      return SongImportResult(success: true, songCount: songs.length);
    } on FormatException catch (_) {
      // WHY: JSON 以外のファイルを選択した場合も例外を UI へ出さず
      // 失敗結果として返す。
      return const SongImportResult(
        success: false,
        message: 'JSON として解釈できませんでした。',
      );
    } on BlobStoreQuotaException catch (_) {
      return const SongImportResult(
        success: false,
        message: '保存領域の空き容量が足りません。',
      );
    } on Exception catch (_) {
      return const SongImportResult(
        success: false,
        message: 'ファイルを保存できませんでした。',
      );
    }
  }

  /// 更新結果を最終操作の記録へ変換する。
  SongDbLastOperation _toUpdateOperation(_UpdateOutcome outcome) {
    final SongDbUpdateStatus status = outcome.result.status;
    return SongDbLastOperation(
      kind: SongDbOperationKind.update,
      outcome: _operationOutcomeOf(status),
      at: _clock(),
      // WHY: message は失敗・スキップ理由のみを持つ規約。スキップは元の結果に
      // 理由が無いため、表示できる文言をここで補う。
      message: _operationMessage(status, outcome.result.message),
      // WHY: 失敗・スキップでは取得できた曲数が無いため null のままにする。
      songCount: outcome.remoteSongCount,
      dbVersion: outcome.dbVersion,
    );
  }

  /// 更新ステータスを最終操作の結果へ対応付ける。
  SongDbOperationOutcome _operationOutcomeOf(SongDbUpdateStatus status) {
    if (status == SongDbUpdateStatus.applied ||
        status == SongDbUpdateStatus.upToDate) {
      return SongDbOperationOutcome.success;
    }
    if (status == SongDbUpdateStatus.skippedNoUrl) {
      return SongDbOperationOutcome.skipped;
    }
    return SongDbOperationOutcome.failure;
  }

  /// 記録に残す理由文言。成功時は null（成功は dbVersion で表す）。
  String? _operationMessage(SongDbUpdateStatus status, String? message) {
    if (status == SongDbUpdateStatus.skippedNoUrl) {
      return '配信 URL が未設定です';
    }
    if (status == SongDbUpdateStatus.failed) {
      return message;
    }
    return null;
  }

  /// 最終操作を settings.json へ保存する（既存キーは保持）。
  Future<void> _recordLastOperation(SongDbLastOperation operation) async {
    try {
      final bytes = await blobStore.read(SongDbPaths.settingsRelativePath);
      final Map<String, dynamic> settings = bytes != null
          ? (jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>)
          : <String, dynamic>{};
      settings['lastOperation'] = operation.toJson();
      await blobStore.write(
        SongDbPaths.settingsRelativePath,
        utf8.encode(jsonEncode(settings)),
      );
    } on Exception catch (_) {
      // WHY: 記録は補助情報であり、ここで例外を投げると辞書更新の成否が
      // 反転して UI の結果表示が事実と食い違う。失敗時は記録を諦めて続行する。
    }
  }

  /// settings.json をキーを保持したまま読む（無い・壊れている場合は空）。
  Future<Map<String, dynamic>> _readSettings() async {
    final bytes = await blobStore.read(SongDbPaths.settingsRelativePath);
    if (bytes == null) {
      return <String, dynamic>{};
    }
    try {
      final dynamic decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } on FormatException catch (_) {
      // WHY: 壊れた設定ファイルは空として扱う（次回保存で正常な形に直る）。
    }
    return <String, dynamic>{};
  }

  /// loadStatus 用の設定読み込み（IO 例外も「読めなかった」として扱う）。
  Future<Map<String, dynamic>> _readSettingsForStatus() async {
    try {
      return await _readSettings();
    } on Exception catch (_) {
      // WHY: 権限・ロック等で読めない場合も、表示専用の照会では
      // 「未設定・記録なし」として返して画面を落とさない。
      return <String, dynamic>{};
    }
  }

  /// 辞書ファイル 1 つの状態を読む（BlobStore 経由）。
  ///
  /// WHY: 壊れた JSON や IO エラーで例外を投げるとステータス画面が落ちるため、
  /// 「ファイルが存在する」ことだけは保ち、件数・バージョンは不明（null）にする。
  Future<SongDbSourceStatus> _readSourceStatus(
    String key, {
    required bool withDbVersion,
  }) async {
    try {
      final bytes = await blobStore.read(key);
      if (bytes == null) {
        return const SongDbSourceStatus(exists: false);
      }
      return _parseSourceStatus(
        utf8.decode(bytes),
        withDbVersion: withDbVersion,
      );
    } on Exception catch (_) {
      // WHY: 存在は分かっているが権限・ロック等で読めない場合。exists=false に
      // すると「未取得」と誤表示されるため、件数不明のまま存在を保つ。
      return const SongDbSourceStatus(exists: true);
    }
  }

  /// 辞書ファイルの内容を状態へ解釈する（壊れた JSON は件数不明）。
  SongDbSourceStatus _parseSourceStatus(
    String content, {
    required bool withDbVersion,
  }) {
    try {
      final dynamic decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        return const SongDbSourceStatus(exists: true);
      }
      final Object? songs = decoded['songs'];
      return SongDbSourceStatus(
        exists: true,
        songCount: songs is List ? songs.length : null,
        // WHY: dbVersion はメイン DB のエンベロープにのみ意味がある。
        dbVersion: withDbVersion ? _readIntOrNull(decoded['dbVersion']) : null,
      );
    } on FormatException catch (_) {
      return const SongDbSourceStatus(exists: true);
    }
  }

  /// 配信 URL から JSON エンベロープを取得し、最小限の検証をして返す。
  ///
  /// WHY: 曲 1 件ごとの不正データのスキップは lib/ocr 側リポジトリ実装の
  /// 責務のため、ここではエンベロープの形（songs が配列）のみ検証する。
  Future<Map<String, dynamic>> _fetchEnvelope(String url) async {
    final http.Client client = _httpClientFactory();
    try {
      final http.Response response = await client.get(Uri.parse(url));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['songs'] is! List) {
        throw const FormatException('"songs" 配列を含む JSON ではありません');
      }
      return decoded;
    } finally {
      client.close();
    }
  }

  /// エンベロープから dbVersion を読む。欠落・非数は契約違反として例外にする。
  int _readDbVersion(Map<String, dynamic> envelope) {
    final dynamic value = envelope['dbVersion'];
    if (value is int) {
      return value;
    }
    if (value is String) {
      final int? parsed = int.tryParse(value);
      if (parsed != null) {
        return parsed;
      }
    }
    throw const FormatException('dbVersion が不正です');
  }

  /// メイン DB バイト列から dbVersion を読む。破損時は 0 扱い、
  /// 次回取得で上書きされる。
  Future<int> _readLocalDbVersion(Uint8List mainBytes) async {
    try {
      final dynamic decoded = jsonDecode(utf8.decode(mainBytes));
      if (decoded is Map) {
        return _readIntOrNull(decoded['dbVersion']) ?? 0;
      }
    } on FormatException catch (_) {
      // WHY: 破損ファイルは dbVersion 不明（0）として扱い、上書き修復を許す。
    }
    return 0;
  }

  /// 数値または数値文字列を int として読む。解釈できなければ null。
  int? _readIntOrNull(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  /// メイン DB へエンベロープを保存し、収録曲数を返す。
  Future<int> _saveMainDb(Map<String, dynamic> envelope) async {
    await blobStore.write(
      SongDbPaths.mainDbRelativePath,
      utf8.encode(jsonEncode(envelope)),
    );
    return (envelope['songs'] as List<dynamic>).length;
  }
}

/// 更新処理の結果と、記録に残すサーバー側収録曲数の組。
///
/// WHY: upToDate（ローカルが新しい）ときも「今サーバーにある曲数」を最終操作に
/// 残したいが、公開 API の [SongDbUpdateResult] は現状の意味を変えないため、
/// 内部でのみ持ち回る。
class _UpdateOutcome {
  const _UpdateOutcome({
    required this.result,
    this.remoteSongCount,
    this.dbVersion,
  });

  /// 呼び出し側へ返す公開結果。
  final SongDbUpdateResult result;

  /// 実際に取得できたサーバー側の収録曲数（取得できなければ null）。
  final int? remoteSongCount;

  /// 適用後の DB バージョン（スキップ・失敗時は null）。
  final int? dbVersion;
}
