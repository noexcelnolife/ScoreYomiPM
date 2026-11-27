// PlayRecordRepository のテスト用フェイク。
//
// WHY: UI テスト（FR-4 の保存フロー）ではファイル I/O の実装詳細は対象外。
// インメモリでレコードと画像バイト列を保持する。実装と同じく、レコードが
// 持つのは basename だけ。

import 'dart:typed_data';

import 'package:scoreyomipm/data/play_record.dart';
import 'package:scoreyomipm/data/play_record_bulk_writer.dart';
import 'package:scoreyomipm/data/play_record_repository.dart';

/// インメモリで動作する [PlayRecordRepository] フェイク。
class FakePlayRecordRepository implements PlayRecordRepository {
  FakePlayRecordRepository({
    this.failOnCreate = false,
    this.failOnUpdate = false,
    this.failOnList = false,
  });

  /// id → レコードの内部ストア（テストから直接読み書き可）。
  final Map<String, PlayRecord> store = <String, PlayRecord>{};

  /// 画像のファイル名 → バイト列。存在しない名前は「画像なし」を意味する。
  final Map<String, Uint8List> images = <String, Uint8List>{};

  /// create に渡されたドラフトの履歴（保存内容の検証用）。
  final List<PlayRecordDraft> createdDrafts = <PlayRecordDraft>[];

  /// update に渡されたドラフトの履歴（保存内容の検証用）。
  final Map<String, PlayRecord> updatedRecords = <String, PlayRecord>{};

  /// true なら create が失敗する（保存失敗時の UI を検証するため）。
  final bool failOnCreate;

  /// true なら update が失敗する。
  final bool failOnUpdate;

  /// true なら listAll が失敗する（v4 案1: 取得失敗時は最近の記録セクション非表示を検証）。
  final bool failOnList;

  int _nextId = 1;

  @override
  Future<PlayRecord> create(PlayRecordDraft draft, Uint8List? resultImageBytes) async {
    if (failOnCreate) {
      throw Exception('create failed (fake)');
    }
    createdDrafts.add(draft);
    final String id = 'fake-$_nextId';
    _nextId++;
    // WHY(v4 案2): 本実装と同じく null 画像は空文字パスを用いる。
    final String imageName = resultImageBytes == null ? '' : '$id.png';
    final PlayRecord record = draft.toPlayRecord(
      id: id,
      resultImagePath: imageName,
    );
    if (resultImageBytes != null) {
      images[imageName] = resultImageBytes;
    }
    store[id] = record;
    return record;
  }

  @override
  Future<List<PlayRecord>> listAll() async {
    if (failOnList) {
      throw Exception('listAll failed (fake)');
    }
    return store.values.toList(growable: false);
  }

  @override
  Future<PlayRecord?> findById(String id) async => store[id];

  @override
  Future<PlayRecord> update(String id, PlayRecordDraft draft) async {
    if (failOnUpdate) {
      throw Exception('update failed (fake)');
    }
    final PlayRecord? existing = store[id];
    if (existing == null) {
      throw StateError('unknown id: $id');
    }
    final PlayRecord updated = draft
        .toPlayRecord(
          id: existing.id,
          resultImagePath: existing.resultImagePath,
          playedAt: existing.playedAt,
        )
        .copyWith(songId: existing.songId);
    store[id] = updated;
    updatedRecords[id] = updated;
    return updated;
  }

  @override
  Future<void> delete(String id) async {
    store.remove(id);
  }

  @override
  Future<Uint8List?> readImage(String imageKey) async {
    return images[imageKey];
  }

  @override
  Future<BulkImportResult> importAll(
    List<PlayRecord> records, {
    required bool replaceAll,
    Map<String, Uint8List?>? imageBytesById,
  }) async {
    // フェイク：すべてインポート成功、画像は無視。
    return BulkImportResult(
      imported: records.length,
      skipped: 0,
      missingImages: 0,
    );
  }
}
