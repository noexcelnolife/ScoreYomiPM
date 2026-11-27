/// IO 実装（Android/iOS）向けの [OcrEngine] 生成口。
///
/// `dart:io` と ML Kit に依存する唯一の実装を、Web ビルドの依存グラフへ
/// 引き込まないために条件付き export の片側として分離している。
library;

import 'mlkit_engine.dart';
import 'ocr_engine.dart';

/// ML Kit 実装のエンジンを生成する。
OcrEngine createOcrEngine() => MlKitOcrEngine();
