import 'dart:typed_data';

import 'package:idb_shim/idb.dart';

import 'blob_store.dart';

/// IndexedDB 上の [BlobStore] 実装。
///
/// WHY(idb_shim を使うか): ブラウザの IndexedDB API を `dart:js_interop` で
/// 直接扱うと、トランザクションの完了待ち・キー範囲・例外の型がすべて
/// 手書きの JS ブリッジになる。`idb_shim` は同一 API を Dart 側で抽象化し、
/// テスト用のメモリ実装（`idbFactoryMemory`）も提供するため、ブラウザ無しで
/// 同じ実装を検証できる（MIT・追加承認済み）。
///
/// WHY(ストアを 1 つに固定するか): キーは `records/...` や `songs/...` の
/// ように接頭辞で名前空間を分けており、接頭辞ごとにストアを増やす必要が無い。
/// 1 ストア + キー範囲で `listKeys` / `deleteWhere` を満たせる。
class IdbBlobStore implements BlobStore {
  IdbBlobStore(
    this._factory, {
    this.databaseName = 'scoreyomipm',
    this.storeName = 'blobs',
    this.version = 1,
    this.onFirstWrite,
  });

  final IdbFactory _factory;

  /// 最初の書き込みが成功した直後に 1 回だけ呼ばれるフック。
  ///
  /// WHY(ストアに持たせるか): ブラウザの永続化要求（`navigator.storage.persist`）
  /// は「利用者のデータを保存し始めた」文脈で呼ぶのが筋で、起動直後に呼ぶと
  /// 目的の分からない許可を求めることになる。書き込みの成功はこのクラスしか
  /// 知らないため、コールバックで外へ知らせる（Web 固有 API はここへ持ち込まない。
  /// 本ファイルを VM テストからも import できる状態に保つため）。
  final Future<void> Function()? onFirstWrite;

  bool _firstWriteNotified = false;

  /// IndexedDB のデータベース名（オリジン単位で共有される）。
  final String databaseName;

  /// バイト列を入れるオブジェクトストア名。
  final String storeName;

  /// スキーマ版。ストア構成を変えるときだけ上げる。
  final int version;

  Database? _database;

  /// キーが文字列の前提で、接頭辞の上限を作る。
  ///
  /// WHY(上限を求めるか): IndexedDB の `KeyRange.bound` は「この範囲」で
  /// 走査を絞れる。接頭辞そのものより大きい最小の文字列は末尾に U+FFFF を
  /// 足したもので、これで `<prefix>*` の範囲を過不足なく覆える。
  static String _upperBound(String prefix) => '$prefix\u{FFFF}';

  Future<Database> _open() async {
    final Database? opened = _database;
    if (opened != null) {
      return opened;
    }
    final Database database = await _factory.open(
      databaseName,
      version: version,
      onUpgradeNeeded: (VersionChangeEvent event) {
        final Database db = event.database;
        if (!db.objectStoreNames.contains(storeName)) {
          db.createObjectStore(storeName);
        }
      },
    );
    _database = database;
    return database;
  }

  @override
  Future<Uint8List?> read(String key) async {
    final Database db = await _open();
    final Transaction txn = db.transaction(storeName, idbModeReadOnly);
    final Object? value = await txn.objectStore(storeName).getObject(key);
    await txn.completed;
    return _asBytes(value);
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    try {
      final Database db = await _open();
      final Transaction txn = db.transaction(storeName, idbModeReadWrite);
      // WHY(コピーを渡すか): 呼び出し元が同じバッファを使い回しても、
      // 書き込み後に中身が変わらないようにする（IndexedDB は値を複製して
      // 保持するが、渡す時点の内容を確定させておく）。
      await txn.objectStore(storeName).put(Uint8List.fromList(bytes), key);
      await txn.completed;
    } on Object catch (error) {
      // WHY(容量エラーだけ翻訳するか): ブラウザの容量切れは利用者が対処できる
      // 唯一の失敗で、対処（不要な記録の削除・バックアップの書き出し）を促す
      // 文言を出し分ける必要がある。それ以外の失敗は原因不明としてそのまま
      // 伝える（握り潰すと保存できていないのに成功したように見える）。
      if (_isQuotaError(error)) {
        throw const BlobStoreQuotaException(
          '保存領域の空き容量が足りません。バックアップを書き出したうえで、不要な記録を削除してください。',
        );
      }
      rethrow;
    }
    await _notifyFirstWrite();
  }

  /// 最初の書き込み成功後に [onFirstWrite] を 1 回だけ呼ぶ。
  ///
  /// WHY(失敗を無視するか): 永続化の要求は「できれば容量を確保しておきたい」
  /// という改善要望で、拒否されても保存自体は成立している。ここで例外を投げると
  /// 正常な保存を失敗として扱ってしまう。
  Future<void> _notifyFirstWrite() async {
    final Future<void> Function()? callback = onFirstWrite;
    if (callback == null || _firstWriteNotified) {
      return;
    }
    _firstWriteNotified = true;
    try {
      await callback();
    } on Object {
      // 意図的に無視する（上記 WHY）。
    }
  }

  /// 容量切れを表すエラーかどうか。
  ///
  /// WHY(文字列で判定するか): IndexedDB の失敗は idb_shim がブラウザの
  /// `DOMException` をそのまま包んで投げるため、Dart 側に共通の型が無い。
  /// 各ブラウザの name（`QuotaExceededError` / 旧 WebKit の
  /// `QUOTA_EXCEEDED_ERR`）とメッセージの両方を見て拾う。
  static bool _isQuotaError(Object error) =>
      error.toString().toLowerCase().contains('quota');

  @override
  Future<void> delete(String key) async {
    final Database db = await _open();
    final Transaction txn = db.transaction(storeName, idbModeReadWrite);
    await txn.objectStore(storeName).delete(key);
    await txn.completed;
  }

  @override
  Future<bool> exists(String key) async => await read(key) != null;

  @override
  Future<List<String>> listKeys(String prefix) async {
    final Database db = await _open();
    final Transaction txn = db.transaction(storeName, idbModeReadOnly);
    final List<Object> keys = await txn.objectStore(storeName).getAllKeys(
      KeyRange.bound(prefix, _upperBound(prefix), false, true),
    );
    await txn.completed;
    final List<String> result = keys.whereType<String>().toList();
    result.sort();
    return result;
  }

  @override
  Future<void> deleteWhere(String prefix) async {
    final Database db = await _open();
    final Transaction txn = db.transaction(storeName, idbModeReadWrite);
    final ObjectStore store = txn.objectStore(storeName);
    await store.delete(KeyRange.bound(prefix, _upperBound(prefix), false, true));
    await txn.completed;
  }

  /// IndexedDB から返る値をバイト列へ正規化する。
  ///
  /// WHY(複数の型を受けるか): ブラウザは保存した値を JS の型として返すため、
  /// 環境によって `Uint8List` / `ByteBuffer` / `List<int>` のいずれにもなり得る。
  /// ここで吸収しないと、画像の表示だけが「読めない」形で壊れる。
  static Uint8List? _asBytes(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is Uint8List) {
      return value;
    }
    if (value is ByteBuffer) {
      return value.asUint8List();
    }
    if (value is TypedData) {
      return value.buffer.asUint8List(
        value.offsetInBytes,
        value.lengthInBytes,
      );
    }
    if (value is List<int>) {
      return Uint8List.fromList(value);
    }
    if (value is List<Object?>) {
      return Uint8List.fromList(value.whereType<int>().toList());
    }
    return null;
  }
}
