import 'dart:io';
import 'dart:typed_data';

/// プラットフォーム共通のブロブストア抽象。
///
/// ファイルシステム・メモリ上の生バイト列をキー値で読み書きする。
/// UI 層・ドメイン層はこの抽象のみに依存し、具体的なストレージ実装に
/// 依存しない（DIP）。
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

/// ファイルシステム上の [BlobStore] 実装。
///
/// [baseDirectory] を基点とし、[key] は `/` 区切りの相対パスとして解決される。
/// `..` を含むキーはパストラバーサル攻撃の対象となるため拒否する。
class IoBlobStore implements BlobStore {
  /// 基点ディレクトリ。相対パスの解決基準となる。
  final Directory baseDirectory;

  IoBlobStore(this.baseDirectory);

  @override
  Future<Uint8List?> read(String key) async {
    _validateKey(key);
    final file = File('${baseDirectory.path}/${_toNativePath(key)}');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    _validateKey(key);
    final file = File('${baseDirectory.path}/${_toNativePath(key)}');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  @override
  Future<void> delete(String key) async {
    _validateKey(key);
    final file = File('${baseDirectory.path}/${_toNativePath(key)}');
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> exists(String key) async {
    _validateKey(key);
    final file = File('${baseDirectory.path}/${_toNativePath(key)}');
    return await file.exists();
  }

  @override
  Future<List<String>> listKeys(String prefix) async {
    _validateKeyPrefix(prefix);
    final dir = Directory('${baseDirectory.path}/${_toNativePath(prefix)}');
    if (!await dir.exists()) {
      // prefix がファイルの場合、そのファイル単体で返す
      final file = File('${baseDirectory.path}/${_toNativePath(prefix)}');
      if (await file.exists()) return [prefix];
      return [];
    }
    final result = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final rel = _toKeyPath(entity.path);
        if (rel.startsWith(prefix)) result.add(rel);
      }
    }
    result.sort();
    return result;
  }

  @override
  Future<void> deleteWhere(String prefix) async {
    _validateKeyPrefix(prefix);
    final dir = Directory('${baseDirectory.path}/${_toNativePath(prefix)}');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      return;
    }
    final file = File('${baseDirectory.path}/${_toNativePath(prefix)}');
    if (await file.exists()) await file.delete();
  }

  /// key をネイティブファイルシステムパスに変換する（`/` → ディレクトリ区切り文字）。
  String _toNativePath(String key) {
    if (Platform.isWindows) return key.replaceAll('/', '\\');
    return key;
  }

  /// ネイティブファイルシステムパスを key 形式に変換する（ディレクトリ区切り文字 → `/`）。
  String _toKeyPath(String path) {
    if (Platform.isWindows) return path.replaceAll('\\', '/');
    return path;
  }

  /// パストラバーサル攻撃を防ぐため、キーに `..` セグメントを含む場合は拒否する。
  void _validateKey(String key) {
    final segments = key.split('/');
    if (segments.any((s) => s == '..')) {
      throw ArgumentError.value(key, 'key', 'パストラバーサルが検出されました（「.." は使用できません）');
    }
    if (key.startsWith(Platform.pathSeparator) ||
        (Platform.isWindows && key.contains(RegExp(r'^[a-zA-Z]:\\')))) {
      throw ArgumentError.value(key, 'key', '絶対パスは使用できません');
    }
  }

  /// prefix もキーとして扱うため、同様に `..` を拒否する。
  void _validateKeyPrefix(String prefix) {
    if (prefix.isEmpty) return;
    _validateKey(prefix);
  }
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
