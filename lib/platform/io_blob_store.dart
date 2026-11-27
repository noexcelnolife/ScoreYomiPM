import 'dart:io';
import 'dart:typed_data';

import 'blob_store.dart';

/// ファイルシステム上の [BlobStore] 実装。
///
/// [baseDirectory] を基点とし、[key] は `/` 区切りの相対パスとして解決される。
/// `..` を含むキーはパストラバーサル攻撃の対象となるため拒否する。
///
/// 書き込みは同ディレクトリの `<key>.tmp` に一時書き出し後 `rename` で
/// 原子的に更新する（途中で落ちても壊れた JSON を残さない）。
class IoBlobStore implements BlobStore {
  /// 基点ディレクトリ。相対パスの解決基準となる。
  final Directory baseDirectory;

  IoBlobStore(this.baseDirectory);

  @override
  Future<Uint8List?> read(String key) async {
    _validateKey(key);
    final file = File(_path(key));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    _validateKey(key);
    final target = File(_path(key));
    await target.parent.create(recursive: true);

    // 原子的更新：同ディレクトリの .tmp に書いてから rename
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes);
    await tmp.rename(target.path);
  }

  @override
  Future<void> delete(String key) async {
    _validateKey(key);
    final file = File(_path(key));
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> exists(String key) async {
    _validateKey(key);
    final file = File(_path(key));
    return await file.exists();
  }

  @override
  Future<List<String>> listKeys(String prefix) async {
    _validateKeyPrefix(prefix);
    final dir = Directory(_path(prefix));
    if (!await dir.exists()) {
      // prefix がファイルの場合、そのファイル単体で返す
      final file = File(_path(prefix));
      if (await file.exists()) return [prefix];
      return [];
    }
    final result = <String>[];
    final base = baseDirectory.path;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        final abs = entity.path;
        if (!abs.startsWith(base)) continue;
        var rel = abs.substring(base.length);
        while (rel.isNotEmpty && (rel[0] == '/' || rel[0] == '\\')) {
          rel = rel.substring(1);
        }
        rel = _toKeyPath(rel);
        if (rel.startsWith(prefix)) result.add(rel);
      }
    }
    result.sort();
    return result;
  }

  @override
  Future<void> deleteWhere(String prefix) async {
    _validateKeyPrefix(prefix);
    final dir = Directory(_path(prefix));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      return;
    }
    final file = File(_path(prefix));
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

  /// baseDirectory と key をプラットフォーム適切な区切り文字で連結する。
  String _path(String key) {
    final sep = Platform.isWindows ? '\\' : '/';
    final base = baseDirectory.path;
    final b = base.endsWith(sep) || base.endsWith(Platform.isWindows ? '/' : '\\')
        ? base
        : '$base$sep';
    return '$b${_toNativePath(key)}';
  }

  /// パストラバーサル攻撃を防ぐため、キーに `..` セグメントを含む場合は拒否する。
  ///
  /// key は常に `/` 区切りなので、先頭の `/` も絶対パスとして拒否し、
  /// Windows ドライブ文字（`C:/` や `C:\`）も拒否する。
  void _validateKey(String key) {
    final segments = key.split('/');
    if (segments.any((s) => s == '..')) {
      throw ArgumentError.value(key, 'key', 'パストラバーサルが検出されました（「..」は使用できません）');
    }
    if (key.startsWith('/')) {
      throw ArgumentError.value(key, 'key', '絶対パスは使用できません');
    }
    if (Platform.isWindows && RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(key)) {
      throw ArgumentError.value(key, 'key', '絶対パスは使用できません');
    }
  }

  /// prefix もキーとして扱うため、同様に `..` を拒否する。
  void _validateKeyPrefix(String prefix) {
    if (prefix.isEmpty) return;
    _validateKey(prefix);
  }
}
