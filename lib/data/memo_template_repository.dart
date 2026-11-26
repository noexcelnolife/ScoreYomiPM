// メモのプリセット（テンプレート）の永続化。
//
// WHY 記録とは別ファイルにしたか: テンプレートは「入力の補助データ」であり、
// 記録（records.json）のスキーマや既存の読み書き経路に手を入れずに済ませたい。
// 壊れたときに影響が及ぶ範囲もテンプレートだけに閉じる。
//
// 保存方式は records.json と揃えている（tmp→rename のアトミック書き込み、
// パース失敗時は .corrupt.<timestamp> へ退避して空リストで復帰）。
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'memo_template.dart';

/// メモテンプレートの永続化抽象（UI はこの抽象のみに依存する）。
abstract class MemoTemplateRepository {
  /// 保存済みテンプレートを返す（並びは作成順）。
  Future<List<MemoTemplate>> listAll();

  /// 新規テンプレートを追加して返す（id は実装が発行する）。
  Future<MemoTemplate> add({required String title, required String body});

  /// 既存テンプレートを差し替えて返す（未知の id は StateError）。
  Future<MemoTemplate> update(MemoTemplate template);

  /// 指定 id を削除する（未知の id は無音で成功・冪等）。
  Future<void> delete(String id);

  /// バックアップ由来のテンプレートを**追加のみ**で取り込む（戻り値は追加件数）。
  ///
  /// 既に同じ id があれば何もしない（同じ ZIP を 2 回復元しても重複しない）。
  /// 既存テンプレートは削除しない。WHY: 「復元」は記録側こそ全消しの選択肢があるが、
  /// テンプレートは記録とは別に育てた入力補助で、記録の復元に巻き込んで消すのは
  /// 利用者の意図から外れやすい。
  Future<int> mergeAll(List<MemoTemplate> templates);
}

/// ファイルベースの [MemoTemplateRepository] 実装。
class FileMemoTemplateRepository implements MemoTemplateRepository {
  FileMemoTemplateRepository({required this._documentsDirectoryResolver});

  static const String _dirName = 'memo_templates';
  static const String _fileName = 'templates.json';
  static const String _tmpSuffix = '.tmp';
  static const String _corruptSuffix = '.corrupt.';
  static const String _logName = 'memo_template_repository';

  /// WHY: documents ディレクトリの解決は実行環境依存のため関数として注入する
  /// （PlayRecordRepository と同じ理由・テストでは一時ディレクトリへ差し替える）。
  final Future<Directory> Function() _documentsDirectoryResolver;

  /// プロセス内 ID 採番シーケンス（同一μ秒でも重複しない接尾辞）。
  int _idSequence = 0;

  @override
  Future<List<MemoTemplate>> listAll() async {
    return _readAll(await _templatesDirectory());
  }

  @override
  Future<MemoTemplate> add({
    required String title,
    required String body,
  }) async {
    final Directory dir = await _templatesDirectory();
    final List<MemoTemplate> templates = await _readAll(dir);
    final MemoTemplate template = MemoTemplate(
      id: _generateId(),
      title: title.trim(),
      body: body.trim(),
    );
    templates.add(template);
    await _writeAll(dir, templates);
    return template;
  }

  @override
  Future<MemoTemplate> update(MemoTemplate template) async {
    final Directory dir = await _templatesDirectory();
    final List<MemoTemplate> templates = await _readAll(dir);
    final int index = templates.indexWhere(
      (MemoTemplate item) => item.id == template.id,
    );
    if (index < 0) {
      throw StateError('未知のメモテンプレート id: ${template.id}');
    }
    // WHY: 呼び出し側の入力をそのまま保存せず trim して揃える（一覧の見た目が
    // 入力時の空白に左右されないようにする）。
    templates[index] = template.copyWith(
      title: template.title.trim(),
      body: template.body.trim(),
    );
    await _writeAll(dir, templates);
    return templates[index];
  }

  @override
  Future<void> delete(String id) async {
    final Directory dir = await _templatesDirectory();
    final List<MemoTemplate> templates = await _readAll(dir);
    final int before = templates.length;
    templates.removeWhere((MemoTemplate item) => item.id == id);
    if (templates.length == before) {
      // 冪等: 既に無い場合は書き込みもしない（不要な I/O を避ける）。
      return;
    }
    await _writeAll(dir, templates);
  }

  @override
  Future<int> mergeAll(List<MemoTemplate> templates) async {
    if (templates.isEmpty) {
      return 0;
    }
    final Directory dir = await _templatesDirectory();
    final List<MemoTemplate> existing = await _readAll(dir);
    final Set<String> existingIds = <String>{
      for (final MemoTemplate item in existing) item.id,
    };
    final List<MemoTemplate> added = templates
        // Set.add が true を返す＝まだ無い id。ZIP 内での id 重複も同時に落とせる。
        .where((MemoTemplate item) => existingIds.add(item.id))
        .toList();
    if (added.isEmpty) {
      return 0;
    }
    // WHY 1 回だけ書くか: 件数分の書き込みは途中失敗で半端な状態を作りうる。
    // 追記分をまとめてアトミックに書き切る。
    await _writeAll(dir, <MemoTemplate>[...existing, ...added]);
    return added.length;
  }

  Future<Directory> _templatesDirectory() async {
    final Directory documents = await _documentsDirectoryResolver();
    return Directory('${documents.path}/$_dirName');
  }

  /// ユニークな ID を生成する（μ秒タイムスタンプ＋採番接尾辞）。
  String _generateId() {
    final int micros = DateTime.now().microsecondsSinceEpoch;
    _idSequence = (_idSequence + 1) % 1000000;
    return 't$micros-$_idSequence';
  }

  /// 全件を読み出す。パース失敗時は退避して空リストを返す。
  Future<List<MemoTemplate>> _readAll(Directory dir) async {
    final File file = File('${dir.path}/$_fileName');
    if (!await file.exists()) {
      return <MemoTemplate>[];
    }
    final String content = await file.readAsString();
    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException catch (error, stackTrace) {
      await _backupCorruptFile(file, error, stackTrace);
      return <MemoTemplate>[];
    }
    if (decoded is! List) {
      await _backupCorruptFile(
        file,
        const FormatException('templates.json は配列ではありません'),
        StackTrace.current,
      );
      return <MemoTemplate>[];
    }
    final List<MemoTemplate> templates = <MemoTemplate>[];
    for (final dynamic entry in decoded) {
      try {
        if (entry is Map<String, dynamic>) {
          templates.add(MemoTemplate.fromJson(entry));
        }
      } catch (error, stackTrace) {
        // WHY: 1 件単位の不正要素はスキップのみ（ファイル全体は正当な JSON。
        // records.json と同じ方針に揃える）。
        developer.log(
          'templates.json の不正要素をスキップ: $error',
          name: _logName,
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return templates;
  }

  /// 破損した templates.json を復旧用にリネーム退避する。
  Future<void> _backupCorruptFile(
    File file,
    Object error,
    StackTrace stackTrace,
  ) async {
    final String timestamp = DateTime.now().microsecondsSinceEpoch.toString();
    final File backupFile = File('${file.path}$_corruptSuffix$timestamp');
    try {
      await file.rename(backupFile.path);
      developer.log(
        'templates.json を破損退避: ${backupFile.path}',
        name: _logName,
        error: error,
        stackTrace: stackTrace,
      );
    } on FileSystemException catch (renameError, renameStackTrace) {
      // WHY: 退避できなくても空リストで継続する。原本を上書き破棄しないことが
      // 最優先（records.json と同じ判断）。
      developer.log(
        'templates.json の破損退避に失敗: $renameError',
        name: _logName,
        stackTrace: renameStackTrace,
      );
    }
  }

  /// 全件を tmp→rename でアトミックに保存する。
  Future<void> _writeAll(Directory dir, List<MemoTemplate> templates) async {
    await dir.create(recursive: true);
    final File file = File('${dir.path}/$_fileName');
    final File tmpFile = File('${file.path}$_tmpSuffix');
    await tmpFile.writeAsString(
      jsonEncode(<Map<String, dynamic>>[
        for (final MemoTemplate template in templates) template.toJson(),
      ]),
      flush: true,
    );
    await tmpFile.rename(file.path);
  }
}
