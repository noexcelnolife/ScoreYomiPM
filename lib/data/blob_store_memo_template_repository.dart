// メモテンプレートを BlobStore に保存する実装。
//
// WHY: Web（IndexedDB）では dart:io の File が使えないため、
// FileMemoTemplateRepository の代わりに BlobStore 経由で保存する。
// 保存は 1 キー（memo_templates/templates.json）、JSON 配列のまま。
//
// 破損時の退避は「BlobStore のキーを *.corrupt.<timestamp> へコピー」に読み替える。
// Web では rename（移動）ではなくコピー＋元削除で対応する（IndexedDB で rename は未サポート）。
import 'dart:convert';
import 'dart:developer' as developer;

import 'memo_template.dart';
import 'memo_template_repository.dart';
import '../platform/blob_store.dart';

/// BlobStore ベースの [MemoTemplateRepository] 実装（Web 対応）。
class BlobStoreMemoTemplateRepository implements MemoTemplateRepository {
  BlobStoreMemoTemplateRepository(this._blobStore);

  final BlobStore _blobStore;

  static const String _fileName = 'memo_templates/templates.json';
  static const String _corruptSuffix = '.corrupt.';
  static const String _logName = 'blob_store_memo_template_repository';

  /// プロセス内 ID 採番シーケンス（同一μ秒でも重複しない接尾辞）。
  int _idSequence = 0;

  /// ユニークな ID を生成する（μ秒タイムスタンプ＋採番接尾辞）。
  String _generateId() {
    final int micros = DateTime.now().microsecondsSinceEpoch;
    _idSequence = (_idSequence + 1) % 1000000;
    return 't$micros-$_idSequence';
  }

  @override
  Future<List<MemoTemplate>> listAll() async {
    final bytes = await _blobStore.read(_fileName);
    if (bytes == null) {
      return <MemoTemplate>[];
    }

    final String content = utf8.decode(bytes);
    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException catch (error, stackTrace) {
      await _backupCorruptBlob(error, stackTrace);
      return <MemoTemplate>[];
    }
    if (decoded is! List) {
      await _backupCorruptBlob(
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

  @override
  Future<MemoTemplate> add({
    required String title,
    required String body,
  }) async {
    final List<MemoTemplate> templates = await listAll();
    final MemoTemplate template = MemoTemplate(
      id: _generateId(),
      title: title.trim(),
      body: body.trim(),
    );
    templates.add(template);
    await _writeAll(templates);
    return template;
  }

  @override
  Future<MemoTemplate> update(MemoTemplate template) async {
    final List<MemoTemplate> templates = await listAll();
    final int index = templates.indexWhere(
      (MemoTemplate item) => item.id == template.id,
    );
    if (index < 0) {
      throw StateError('未知のメモテンプレート id: ${template.id}');
    }
    templates[index] = template.copyWith(
      title: template.title.trim(),
      body: template.body.trim(),
    );
    await _writeAll(templates);
    return templates[index];
  }

  @override
  Future<void> delete(String id) async {
    final List<MemoTemplate> templates = await listAll();
    final int before = templates.length;
    templates.removeWhere((MemoTemplate item) => item.id == id);
    if (templates.length == before) {
      // 冪等: 既に無い場合は書き込みもしない（不要な I/O を避ける）。
      return;
    }
    await _writeAll(templates);
  }

  @override
  Future<int> mergeAll(List<MemoTemplate> templates) async {
    if (templates.isEmpty) {
      return 0;
    }
    final List<MemoTemplate> existing = await listAll();
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
    await _writeAll(<MemoTemplate>[...existing, ...added]);
    return added.length;
  }

  /// 破損した templates.json を退避用キーにコピーし、元を削除する。
  Future<void> _backupCorruptBlob(Object error, StackTrace stackTrace) async {
    final String timestamp = DateTime.now().microsecondsSinceEpoch.toString();
    final String backupKey = '$_fileName$_corruptSuffix$timestamp';
    try {
      final bytes = await _blobStore.read(_fileName);
      if (bytes != null) {
        await _blobStore.write(backupKey, bytes);
        await _blobStore.delete(_fileName);
        developer.log(
          'templates.json を破損退避: $backupKey',
          name: _logName,
          error: error,
          stackTrace: stackTrace,
        );
      }
    } on Object catch (copyError, copyStackTrace) {
      // WHY: 退避できなくても空リストで継続する。原本を上書き破棄しないことが
      // 最優先（records.json と同じ判断）。
      developer.log(
        'templates.json の破損退避に失敗: $copyError',
        name: _logName,
        stackTrace: copyStackTrace,
      );
    }
  }

  /// 全件を JSON 配列としてアトミックに保存する（上書き）。
  Future<void> _writeAll(List<MemoTemplate> templates) async {
    final String json = jsonEncode(<Map<String, dynamic>>[
      for (final MemoTemplate template in templates) template.toJson(),
    ]);
    await _blobStore.write(_fileName, utf8.encode(json));
  }
}
