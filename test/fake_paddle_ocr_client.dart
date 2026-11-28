// PaddleOcrClient のテスト用フェイク。

import 'dart:typed_data';

import 'package:scoreyomipm/models/ocr_models.dart';
import 'package:scoreyomipm/ocr/paddle_ocr_engine.dart';

/// [PaddleOcrClient] のテスト用フェイク。
///
/// WHY(呼び出しを記録するか): この層の契約は「JS 側に何を渡し、何回呼ぶか」
/// にある（クロップ後の寸法・再試行の回数）。戻り値だけ見ても検証できない。
class FakePaddleOcrClient extends PaddleOcrClient {
  /// [responses] は detect の呼び出し順の応答。要素列か、投げる [Exception]。
  FakePaddleOcrClient({required List<Object> responses})
    : _responses = List<Object>.of(responses);

  final List<Object> _responses;

  /// detect に渡されたバイト列（呼び出し順）。
  final List<Uint8List> receivedBytes = <Uint8List>[];

  /// dispose が呼ばれた回数。
  int disposeCount = 0;

  @override
  Future<List<OcrElement>> detect(Uint8List encodedImageBytes) async {
    receivedBytes.add(encodedImageBytes);
    final int index = receivedBytes.length - 1;
    // WHY(想定外の呼び出しを失敗させるか): 再試行が余計に走ったことを
    // 「回数」ではなく「例外」で検出できるようにする。
    if (index >= _responses.length) {
      throw StateError('想定より多く detect が呼ばれた（${receivedBytes.length} 回目）');
    }
    final Object response = _responses[index];
    if (response is Exception) {
      throw response;
    }
    return response as List<OcrElement>;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

/// 初回読み込み状態を名乗るフェイク。
///
/// WHY(サブクラスか): [PaddleOcrEngine] は `isPreparing` をクライアントへ
/// 委譲する。準備中と準備済みの両方を同じテストから作れるようにする。
class LoadStateFakePaddleOcrClient extends FakePaddleOcrClient {
  LoadStateFakePaddleOcrClient({
    required super.responses,
    required this.isPreparing,
  });

  @override
  final bool isPreparing;
}
