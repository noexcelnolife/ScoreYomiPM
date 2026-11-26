import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;
import 'package:material_ui/material_ui.dart';

import 'capture_guide_overlay.dart';

/// 撮影画面を閉じたときの結果種別。
enum CaptureOutcomeKind {
  /// 撮影成功（[CaptureOutcome.path] に画像パス）。
  captured,

  /// カメラ初期化に失敗。既存の image_picker カメラ経路へフォールバックする
  /// （FR-9 v3 基線 845997d/4909a58 を消さず防御層として維持する契約）。
  fallback,

  /// カメラ権限拒否。SnackBar 通知のうえギャラリー選択へ誘導する。
  permissionDenied,

  /// ユーザーが撮影画面からギャラリー選択を選んだ。
  gallery,
}

/// 撮影画面の結果。
class CaptureOutcome {
  const CaptureOutcome.captured(String this.path)
    : kind = CaptureOutcomeKind.captured;

  const CaptureOutcome.fallback()
    : kind = CaptureOutcomeKind.fallback,
      path = null;

  const CaptureOutcome.permissionDenied()
    : kind = CaptureOutcomeKind.permissionDenied,
      path = null;

  const CaptureOutcome.gallery()
    : kind = CaptureOutcomeKind.gallery,
      path = null;

  final CaptureOutcomeKind kind;

  /// 撮影画像のパス（[CaptureOutcomeKind.captured] のみ非 null）。
  final String? path;
}

/// カメラセッションの抽象（DIP）。
///
/// WHY 抽象化: カメラはプラットフォームチャネル依存で widget テストから
/// 実体を動かせない。画面側は本抽象だけに依存させ、テストでは偽セッションで
/// 「成功・権限拒否・一般失敗」の分岐を決定的に検証する。
abstract class CaptureSession {
  /// カメラを初期化する。失敗は例外で通知（画面側が種別判定する）。
  Future<void> initialize();

  /// プレビュー widget（実装は CameraPreview 等）。
  Widget buildPreview(BuildContext context);

  /// 静止画を撮影し、保存先パスを返す（失敗時 null）。
  Future<String?> capture();

  /// カメラ資源の解放。
  Future<void> dispose();
}

/// セッション生成関数（テストで差し替える）。
typedef CaptureSessionFactory = Future<CaptureSession> Function();

/// 公式 camera プラグインによる実装。
///
/// WHY 背面カメラ固定: リザルト画面は画面（ディスプレイ）を撮るため背面が
/// 適切。背面が無い機種（一部タブレット・エミュレータ）は先頭カメラへ
/// フォールバックする。
class CameraPluginCaptureSession implements CaptureSession {
  CameraController? _controller;

  @override
  Future<void> initialize() async {
    final List<CameraDescription> cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw CameraException('NoCameraAvailable', '利用可能なカメラがありません');
    }
    final CameraDescription description = cameras.firstWhere(
      (CameraDescription c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final CameraController controller = CameraController(
      description,
      // WHY veryHigh（ユーザー要望「OCR に回す解像度を上げたい」2026-11-24）:
      // 横向き固定（`_captureOrientations`）でガイド枠の面積は約 3 倍になった
      // が、撮影 JPEG の寸法はプリセット依存で、`high` の実測は 1280×720
      // だった（エミュレータ・縦横とも同値）。1 段上の veryHigh を指定する。
      //
      // 実寸は端末のカメラ HAL が対応解像度の中から決める。エミュレータでは
      // HAL の 16:9 上限が 1280×720 のため（`dumpsys media.camera` の
      // availableStreamConfigurations に 1920×1080 が存在しない）、veryHigh
      // でも high と同じ 1280×720 のまま = **エミュレータでは指定は無効**。
      // 上位端末ではより高い解像度が選ばれる想定だが、本環境では未実証。
      // 撮影画面はプレビューを letterbox 表示するだけで、ガイド枠の幾何は
      // キャンバス基準（guideRectFor）なのでプリセット変更の影響を受けない。
      ResolutionPreset.veryHigh,
      enableAudio: false,
    );
    await controller.initialize();
    _controller = controller;
  }

  @override
  Widget buildPreview(BuildContext context) {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return CameraPreview(controller);
  }

  @override
  Future<String?> capture() async {
    final CameraController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return null;
    }
    final XFile file = await controller.takePicture();
    return file.path;
  }

  @override
  Future<void> dispose() async {
    await _controller?.dispose();
  }
}

Future<CaptureSession> _defaultSessionFactory() async {
  final CameraPluginCaptureSession session = CameraPluginCaptureSession();
  await session.initialize();
  return session;
}

/// 撮影中の向き（横向き固定・左右両対応）。
///
/// WHY 横向き既定（ユーザー実機フィードバック 2026-11-24）: 撮影対象の
/// リザルト画面は横長で、縦長画面の中央帯に写すと上下が無駄になり OCR へ
/// 渡るリザルト領域の有効画素が減る。横向きにするとプレビュー・撮影 JPEG
/// とも横長（1920×1080 系）で保存され、同じ距離でもリザルト領域の画素数が
/// 増える。左右両対応にするのは、端末を左右どちらに構えても撮れるようにする
/// ため（片側固定は撮影姿勢を強制してしまう）。
const List<DeviceOrientation> _captureOrientations = <DeviceOrientation>[
  DeviceOrientation.landscapeLeft,
  DeviceOrientation.landscapeRight,
];

/// FR-9 案A: アプリ内撮影画面（CameraPreview + 静的ガイド枠 + シャッター）。
///
/// ユーザー指示（2026-11-24）「撮影ガイド枠を実装してください」。
/// 撮影した画像は結果として呼び出し元へ返し、既存の OCR パイプラインへ
/// 合流させる（本画面は OCR に依存しない = lib/ocr と完全独立）。
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    this.sessionFactory = _defaultSessionFactory,
  });

  /// セッション生成（既定は公式 camera プラグイン）。
  final CaptureSessionFactory sessionFactory;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  CaptureSession? _session;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // WHY 表示時に横向き固定: 撮影中は常に横長で写したいため、カメラ初期化
    // と並行して向きを要求する（初期化失敗で即閉じる場合も、離脱時の復帰が
    // 走るので固定が残らない）。
    _lockLandscape();
    _initialize();
  }

  /// 向きを縦（portraitUp）へ戻す。
  ///
  /// WHY 縦固定へ戻すか: アプリの他画面（ホーム・一覧・詳細・OCR 結果）は
  /// 縦前提のレイアウトで、横向きに最適化していない。撮影のためだけに端末を
  /// 横にした状態が他画面へ持ち越されると、レイアウト崩れと操作不能を招く。
  /// そこで「撮影中だけ横向き・離脱したら縦」という契約にする。
  ///
  /// WHY 完了を待たないか: 向きの適用は OS が非同期に行うもので、pop を
  /// 待たせるとプラットフォーム応答が返らない環境で画面が閉じられなくなる。
  /// 呼び出し順序（pop より前）だけを保証し、適用は OS に委ねる。向き要求の
  /// 失敗も無視する（向きは撮影体験の最適化であって撮影機能の前提ではない）。
  void _restoreOrientation() {
    unawaited(
      SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]).catchError((Object _) {}),
    );
  }

  /// 撮影中の横向き固定を要求する（失敗しても撮影は継続する）。
  void _lockLandscape() {
    unawaited(
      SystemChrome.setPreferredOrientations(_captureOrientations)
          .catchError((Object _) {}),
    );
  }

  Future<void> _initialize() async {
    try {
      final CaptureSession session = await widget.sessionFactory();
      if (!mounted) {
        await session.dispose();
        return;
      }
      setState(() => _session = session);
    } catch (error) {
      if (!mounted) {
        return;
      }
      // WHY コード接頭辞で判定: camera プラグインは権限拒否を
      // CameraException.code = 'CameraAccessDenied' 系で返す（iOS は
      // WithoutPrompt/Restricted もある）。接頭辞一致で権限系を一括判定。
      if (error is CameraException && error.code.startsWith('CameraAccess')) {
        _finish(
          const CaptureOutcome.permissionDenied(),
          'カメラの権限がありません。ギャラリーから選択できます',
        );
      } else {
        _finish(const CaptureOutcome.fallback(), 'カメラを起動できませんでした。標準カメラで撮影します');
      }
    }
  }

  /// 結果を返して画面を閉じる（SnackBar は app 全体の messenger に出すため
  /// pop 後も呼び出し元画面で表示され続ける）。
  ///
  /// 全分岐（captured / fallback / permissionDenied / gallery）が本メソッドを
  /// 通り、pop の直前に向きの復帰要求を必ず発行する。
  void _finish(CaptureOutcome outcome, [String? message]) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    _restoreOrientation();
    Navigator.of(context).pop(outcome);
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// 閉じるボタン（結果なしで戻る）。
  void _close() {
    _restoreOrientation();
    Navigator.of(context).pop();
  }

  Future<void> _capture() async {
    final CaptureSession? session = _session;
    if (session == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final String? path = await session.capture();
      if (!mounted) {
        return;
      }
      if (path == null) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('撮影に失敗しました。もう一度お試しください')));
        return;
      }
      _finish(CaptureOutcome.captured(path));
    } on CameraException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('撮影に失敗しました: ${error.description ?? error.code}'),
        ),
      );
    }
  }

  @override
  void dispose() {
    // WHY ここでも復帰させるか: OS の戻る操作など [_finish]/[_close] を
    // 経由しない破棄でも横向き固定を残さない（復帰要求は冪等なので重複可）。
    _restoreOrientation();
    // WHY fire-and-forget: State.dispose は同期。カメラ解放を待たずに
    // 戻り値契約を素直に保つ（テストでは FakeSession.disposed で観測）。
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CaptureSession? session = _session;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          // 下層: カメラプレビュー（初期化中はインジケータ）。
          Positioned.fill(
            child: session == null
                ? const Center(child: CircularProgressIndicator())
                : Center(child: session.buildPreview(context)),
          ),
          // 上層: 静的ガイド枠（操作は遮らない）。
          const Positioned.fill(child: CaptureGuideOverlay()),
          // 上部: 閉じるボタン。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  key: const ValueKey<String>('capture-close-button'),
                  tooltip: '閉じる',
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _close,
                ),
              ),
            ),
          ),
          // 下部: ギャラリー導線 + シャッター。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: <Widget>[
                    IconButton(
                      key: const ValueKey<String>('capture-gallery-button'),
                      tooltip: 'ギャラリーから選択',
                      icon: const Icon(
                        Icons.photo_library_outlined,
                        color: Colors.white,
                        size: 30,
                      ),
                      onPressed: () => _finish(const CaptureOutcome.gallery()),
                    ),
                    Semantics(
                      button: true,
                      label: '撮影',
                      child: InkWell(
                        key: const ValueKey<String>('capture-shutter-button'),
                        onTap: session == null ? null : _capture,
                        customBorder: const CircleBorder(),
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            border: Border.all(color: Colors.white38, width: 4),
                          ),
                          child: _busy
                              ? const Padding(
                                  padding: EdgeInsets.all(18),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 48, height: 30),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
