import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../data/play_record_repository.dart';

/// 保存先から読み込んだ記録画像を表示する。
///
/// WHY(リポジトリを受け取るか): 画像の実体は端末のディスクにもブラウザの
/// IndexedDB にもある。UI が `File(record.resultImagePath)` を開く書き方だと、
/// basename しか持たない今の `resultImagePath` では必ず失敗する（Web では
/// `dart:io` 自体が実行時に落ちる）。「どこから読むか」はリポジトリの責務に
/// 閉じ込め、UI は名前だけを渡す。
///
/// WHY(StatefulWidget か): `FutureBuilder` に毎 build で新しい Future を渡すと
/// 再描画のたびに読み直しが走る。一覧のスクロールで無駄な I/O を増やさない
/// よう、Future は名前が変わったときだけ作り直す。
class RecordImage extends StatefulWidget {
  const RecordImage({
    super.key,
    required this.repository,
    required this.imageName,
    this.fit = BoxFit.cover,
    this.fallbackIcon = Icons.broken_image_outlined,
  });

  /// 画像の読み出し口。実装（ディスク / IndexedDB）は問わない。
  final PlayRecordRepository repository;

  /// `PlayRecord.resultImagePath`（basename）。空文字を渡してはならない。
  final String imageName;

  final BoxFit fit;

  /// 画像が無い・壊れているときに出すアイコン。
  final IconData fallbackIcon;

  @override
  State<RecordImage> createState() => _RecordImageState();
}

class _RecordImageState extends State<RecordImage> {
  late Future<Uint8List?> _bytes = _load();

  Future<Uint8List?> _load() =>
      widget.repository.readImage(widget.imageName);

  @override
  void didUpdateWidget(RecordImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // WHY: 一覧の行は使い回される。名前か保存先が変わったら読み直さないと、
    // 前の記録の写真が別の行に出る。
    if (oldWidget.imageName != widget.imageName ||
        oldWidget.repository != widget.repository) {
      _bytes = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
        // WHY(空で待つか): 呼び出し側は 56x56 などの枠を用意している。
        // 読み込み中に別のアイコンを出すとチラつくため、枠だけ空ける。
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox.shrink();
        }
        final Uint8List? bytes = snapshot.data;
        if (bytes == null) {
          return Icon(widget.fallbackIcon);
        }
        return Image.memory(
          bytes,
          fit: widget.fit,
          errorBuilder: (_, _, _) => Icon(widget.fallbackIcon),
        );
      },
    );
  }
}
