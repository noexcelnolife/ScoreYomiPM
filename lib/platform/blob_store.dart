import 'dart:typed_data';

/// プラットフォーム共通のブロブストア抽象。
///
/// ファイルシステム・メモリ上の生バイト列をキー値で読み書きする。
/// UI 層・ドメイン層はこの抽象のみに依存し、具体的なストレージ実装に
/// 依存しない（DIP）。
///
/// dart:io を import しない。Web ビルドでもこのファイル単体で import できる。
abstract class BlobStore {
  /// [key] に紐づくバイト列を返す。存在しない場合は `null`。
  Future<Uint8List?> read(String key);

  /// [key] に [bytes] を書き込む。既に存在する場合は上書きする。
  Future<void> write(String key, Uint8List bytes);

  /// [key] に紐づくエントリを削除する。存在しない場合は何もしない。
  Future<void> delete(String key);

  /// [key] が存在する場合は `true` を返す。
  Future<bool> exists(String key);

  /// [prefix] で始まるキーの一覧を昇順で返す。
  Future<List<String>> listKeys(String prefix);

  /// [prefix] で始まるすべてのエントリを削除する。
  Future<void> deleteWhere(String prefix);
}

/// 保存先の空き容量が尽きて書き込めなかったことを表す例外。
///
/// WHY(専用の型にするか): ブラウザでは保存領域の上限がオリジン単位で課され、
/// 上限に達すると以後の書き込みがすべて失敗する。原因が容量であることは
/// 利用者にしか対処できない（不要な記録を消す・バックアップを書き出す）ため、
/// 汎用の失敗と区別して「容量が足りない」と伝えられる必要がある。
///
/// WHY(呼び出し側で握り潰さないか): 書き込みが失敗したまま「保存しました」と
/// 出してはいけない。原画像と記録の両方が失われる経路なので、呼び出し側は
/// 必ず失敗として扱うこと。
class BlobStoreQuotaException implements Exception {
  const BlobStoreQuotaException(this.message);

  /// 利用者向けの説明（原因と対処）。
  final String message;

  @override
  String toString() => 'BlobStoreQuotaException: $message';
}

/// メモリ上の [BlobStore] 実装。テスト用。
class MemoryBlobStore implements BlobStore {
  final Map<String, Uint8List> _store = {};

  @override
  Future<Uint8List?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, Uint8List bytes) async {
    _store[key] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }

  @override
  Future<bool> exists(String key) async => _store.containsKey(key);

  @override
  Future<List<String>> listKeys(String prefix) async {
    final result = _store.keys.where((k) => k.startsWith(prefix)).toList();
    result.sort();
    return result;
  }

  @override
  Future<void> deleteWhere(String prefix) async {
    final keys = _store.keys.where((k) => k.startsWith(prefix)).toList();
    for (final key in keys) {
      _store.remove(key);
    }
  }
}
