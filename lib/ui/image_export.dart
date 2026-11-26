// 原画像を「アプリ外に保存」するときの保存名と MIME タイプを組み立てる。
//
// WHY(純粋関数として分離): 保存名の規則（曲名・recordId・日付・使用不可文字の
// 置換）は画面の状態に依存しない。画面から切り出して単体で検証できるようにし、
// 記録詳細画面の肥大化も避ける（タスク 01a2106d）。
//
// ここに置く関数は副作用を持たない（DateTime も引数で受け取る）。

/// ファイル名に使えない文字（Windows / Android の両方で問題になるもの）。
const String _invalidFileNameChars = '/\\:*?"<>|';

/// 拡張子が取れないときの代替。中身の種類は mimeTypeForImagePath が
/// application/octet-stream を返すため、拡張子だけ汎用にする。
const String _fallbackExtension = 'bin';

/// 保存名を組み立てる。
///
/// 曲名があれば `scoreyomipm_<曲名>_<yyyyMMdd>.<ext>`、無ければ
/// `scoreyomipm_<recordId 先頭8>.<ext>`（曲名で区別できないため日付は付けず、
/// recordId で一意にする）。
String buildImageExportFileName({
  required String recordId,
  required String? songName,
  required String imagePath,
  required DateTime now,
}) {
  final String extension = _extensionOf(imagePath);
  final String title = (songName ?? '').trim();
  final String base;
  if (title.isEmpty) {
    base = 'scoreyomipm_${_sanitize(_shortId(recordId))}';
  } else {
    base = 'scoreyomipm_${_sanitize(title)}_${_formatDate(now)}';
  }
  return '$base.$extension';
}

/// 保存先に渡す MIME タイプを拡張子から決める。
///
/// WHY: 保存ダイアログ（FlutterFileDialog）は MIME タイプで保存先の扱いを
/// 決めるため、画像以外を画像と名乗らないようにする。
String mimeTypeForImagePath(String path) {
  switch (_extensionOf(path)) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    default:
      return 'application/octet-stream';
  }
}

/// パスから小文字の拡張子（先頭のドット無し）を取り出す。
///
/// 拡張子が無い・英数字以外を含む場合は [_fallbackExtension] を返す
/// （保存名に別のディレクトリ区切りなどが混入しないようにするため）。
String _extensionOf(String path) {
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) {
    return _fallbackExtension;
  }
  final String extension = path.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]+$').hasMatch(extension)
      ? extension
      : _fallbackExtension;
}

/// recordId の先頭 8 文字（8 文字未満ならそのまま）。
String _shortId(String recordId) {
  return recordId.length <= 8 ? recordId : recordId.substring(0, 8);
}

/// [value] の使用不可文字を `_` に置換する。
String _sanitize(String value) {
  final StringBuffer buffer = StringBuffer();
  for (final int rune in value.runes) {
    final String character = String.fromCharCode(rune);
    buffer.write(_invalidFileNameChars.contains(character) ? '_' : character);
  }
  return buffer.toString();
}

/// yyyyMMdd 形式の日付。
String _formatDate(DateTime now) {
  final String month = now.month.toString().padLeft(2, '0');
  final String day = now.day.toString().padLeft(2, '0');
  return '${now.year}$month$day';
}
