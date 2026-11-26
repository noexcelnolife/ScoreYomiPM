import 'dart:async';

import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// 共有インテント受信機。
///
/// 冷起動（アプリ未起動時の共有）と温起動（メモリ上のアプリへの共有）の
/// 両方を受け付け、画像ファイルパスを [imagePathStream] でpublish する。
///
/// 画像以外（テキスト・URL等）の共有は [imagePathStream] に流さず、
/// 呼び出し側で「画像ファイルのみ対応」案内を行う。
///
/// WHY: receive_sharing_intent 1.9.0 の API は instance メンバー形式
/// (`ReceiveSharingIntent.instance.getInitialMedia()` /
/// `ReceiveSharingIntent.instance.getMediaStream()`) をとるため、
/// static アクセスではなく instance 経由で呼び出す。
/// receive_sharing_intent の生 API を薄くラップし、HomeScreen 側で
/// OCR run 経路（imageFile → OcrResultScreen）へフィードしやすくする。
/// 既存の撮影・ギャラリー選択経路とは独立し、#13-F キャッシュ契約を
/// 壊さない。
class SharingIntentReceiver {
  SharingIntentReceiver();

  StreamSubscription<List<SharedMediaFile>>? _mediaSubscription;

  /// 初期インテント（冷起動時）から最初の画像パスを取得する。
  ///
  /// アプリが未起動の状態で画像が共有された場合に、起動直後にこのメソッドを
  /// 呼び出すことで共有元の画像パスを取得できる。
  Future<String?> getInitialImagePath() async {
    try {
      final List<SharedMediaFile> files = await ReceiveSharingIntent.instance
          .getInitialMedia();
      return firstImagePath(files);
    } catch (_) {
      return null;
    }
  }

  /// 画像ファイルパスの Stream を購読する（温起動時）。
  ///
  /// アプリがメモリ上にある状態で画像が共有されると、本 Stream にパスが
  /// 発行される。購読は [cancel] で解除すること。
  Stream<String> get imagePathStream {
    final controller = StreamController<String>.broadcast();
    _mediaSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      (List<SharedMediaFile> files) {
        final path = firstImagePath(files);
        if (path != null && !controller.isClosed) {
          controller.add(path);
        }
      },
      onError: (_) {
        // ストリームエラーは無視し、購読を継続する。
      },
    );
    return controller.stream;
  }

  /// 購読を解除する。
  void cancel() {
    _mediaSubscription?.cancel();
    _mediaSubscription = null;
  }

  /// SharedMediaFile リストから最初の画像ファイルパスを抽出する。
  ///
  /// 画像以外（テキスト・URL等）は null を返し、呼び出し側でスキップ案内
  /// を行う。
  ///
  /// WHY: テスト側から非画像フィルタの純関数を単体検証可能にするため
  /// public static に公開する（テストファイルと同じライブラリではないため、
  /// private 参照ではコンパイルエラーとなる）。
  static String? firstImagePath(List<SharedMediaFile> files) {
    for (final file in files) {
      final name = file.path.toLowerCase();
      if (name.endsWith('.jpg') ||
          name.endsWith('.jpeg') ||
          name.endsWith('.png') ||
          name.endsWith('.webp')) {
        return file.path;
      }
    }
    return null;
  }
}
