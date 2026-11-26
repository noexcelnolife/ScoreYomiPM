// v3 入力ソース種別選択シート（01a20785-a302）+ v5 機能 A 機種選択。
// 設計: docs/v3_input_source_flow_design_2026-11-23.md §1（2026-11-23 裁定済み）+
//     docs/fr9_camera_capture_design_confirmation_2026-11-22.md（案A）+
//     docs/v5_difficulty_machine_design_2026-11-23.md §3（機種 chips）。
//
// 種別ごとの入口アクションはコールバックで親（HomeScreen）へ委譲する。親は
// ギャラリー pick と layoutHint 注入（InputLayoutHint.hcV1 / acV1）を担う。
// v5 で各入口に「機種」を添えて通知する（selectedMachine 引数）。
import 'package:material_ui/material_ui.dart';

import '../data/play_record.dart';

/// 入口アクションの型（選択済み機種を伴って親へ返す）。
///
/// WHY 引数追加: 機種はシート側で一度選べば各入口で同じ値を共有したい。
/// 親側で機種状態を持つと OCR 画面リセット時の扱いが複雑化するため、
/// ここだけで保持して「選択時の値」として渡す（親は route 引き継ぎのみ）。
typedef MachineAction = void Function(String? machine);

/// 種別選択シートの本文ウィジェット。
///
/// 行構成（上から順）:
/// - v5 機種 chips（「未指定」/「H☆C!!」/「Lively」）
/// - 「HC プレーシェア」: ギャラリー pick へ直行（hint=hcV1）
/// - 「HC リザルト写真」: 親行 + 「ギャラリーから選択」（hint=acV1）と
///   「カメラで撮影」（Androidのみ・有効化時は hint=acV1 で OCR 実行）
/// - 「Lively」: 親行 + 「ギャラリーから選択」（hint=livelyV1）と
///   「カメラで撮影」（Androidのみ・hint=livelyV1）。
///   2026-11-24 のユーザー指示「統合のストラテジーで Lively も H&C と同様の
///   経路で OCR とスコア登録ができるように」で「準備中」から有効化した。
///   2026-11-26 のユーザー指示「HC のカメラで撮影のようにその場で枠線付きの
///   カメラを起動することはできますか」でカメラ入口を追加した。
/// - 「写真なしで手入力」: 常に最下段。
///   WHY 最下段か（2026-11-26 のユーザー指示）: 上から「写真を撮る/選ぶ」導線を
///   並べ、写真を使わない選択肢だけを最後に置くと、上から順に読み下すだけで
///   目的の入口に着く。手入力は OCR を使わない別系統なので末尾へ分離する。
///
/// WHY StatefulWidget（v5 で変更）: 機種選択はシートを開いている間の一時状態で、
/// 全入口アクションで共有する。StatelessWidget のままでは保持できず、
/// 親へ持ち戻すと「機種を変えたのに入口を選ぶまで記憶されない」構造になるため、
/// シート内 state に閉じこめる（v3 の Stateless 前提は機種導入で不要になった）。
///
/// WHY リザルト写真の 2 アクションを常時表示: 開閉アニメーション
/// （ExpansionTile）を挟むと操作ステップが増えるため、親行の直下に 2 アクション
/// を出す（設計 §1 の「展開」は展開形での提示と解釈）。
///
/// WHY カメラ行の platform gate: Android しかカメラがないため、
/// Windows/Web 等では表示しない（FR-9 §8）。
class SpeciesSelectionSheet extends StatefulWidget {
  const SpeciesSelectionSheet({
    super.key,
    required this.onPickPlayShare,
    required this.onPickResultGallery,
    required this.onPickResultCamera,
    required this.onPickLivelyGallery,
    required this.onPickLivelyCamera,
    required this.onManualEntry,
  });

  /// 「HC プレーシェア」行選択時のコールバック（シートを閉じた後に呼ぶ・機種付き）。
  final MachineAction onPickPlayShare;

  /// 「HC リザルト写真 → ギャラリーから選択」行選択時のコールバック（同上）。
  final MachineAction onPickResultGallery;

  /// 「HC リザルト写真 → カメラで撮影」行選択時のコールバック（同上）。
  final MachineAction onPickResultCamera;

  /// 「Lively → ギャラリーから選択」行選択時のコールバック（同上・機種は Lively 固定）。
  final MachineAction onPickLivelyGallery;

  /// 「Lively → カメラで撮影」行選択時のコールバック（同上・機種は Lively 固定）。
  ///
  /// WHY カメラも用意するか（2026-11-26 のユーザー指示）: Lively は PC 画面なので
  /// 撮るならスマホのカメラで画面を写すことになる。ガイド枠（16:9）は PC 画面の
  /// スコア画面を収める用途にそのまま使え、保存済み画像が無い場面でも取り込める。
  /// 実際のパネル切り出しは OCR 側（LivelyOcrRoute）が行うため、枠は狙いを付ける
  /// ための目安でよい。
  final MachineAction onPickLivelyCamera;

  /// 「写真なしで手入力」行選択時のコールバック（同上・機種付き）。
  final MachineAction onManualEntry;

  @override
  State<SpeciesSelectionSheet> createState() => _SpeciesSelectionSheetState();
}

class _SpeciesSelectionSheetState extends State<SpeciesSelectionSheet> {
  /// 選択済み機種（null = 未指定）。
  ///
  /// WHY 既定を H☆C!!（= [availableGameVersions] の先頭）にしたか
  /// （ユーザー指示 2026-11-24）: 実運用では現行機種以外を選ぶ場面がなく、
  /// 「未指定」が既定のままだと機種を選ばずに保存する取りこぼしが起きる。
  /// 未指定は選択肢として残すため、明示的に外したい場合は従来どおり選べる。
  /// 一覧の先頭を既定にするのは、機種追加時に世代の先頭が現行機種になる
  /// 並び順（[availableGameVersions]）を単一の真実源として使うため。
  String? _machine = availableGameVersions.isEmpty
      ? null
      : availableGameVersions.first;

  /// シートを閉じてから入口アクションを実行する（選択済み機種を添える）。
  ///
  /// WHY: pickImage はシートが閉じきる前に呼んでもよいが、閉じを先に済ませる
  /// ほうがユーザーの視線の推移（シート → ギャラリー）が自然。
  ///
  /// [machineOverride] は「行そのものが機種を決める」入口用（Lively 行）。
  /// 指定時は chip の選択より優先する。
  void _closeAnd(
    BuildContext sheetContext,
    MachineAction action, {
    String? machineOverride,
  }) {
    Navigator.of(sheetContext).pop();
    action(machineOverride ?? _machine);
  }

  /// カメラアクションが表示されるか（platform gate: Android のみ）。
  bool _cameraVisible(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    // WHY SingleChildScrollView: ボトムシートには高さ上限があるため、小画面
    // でも下端の行（手入力）へ到達できるようにスクロール可能にする。
    return SingleChildScrollView(
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _machineChipRow(context),
            _playShareRow(context),
            ..._resultRows(context),
            ..._livelyRows(context),
            _manualEntryRow(context),
          ],
        ),
      ),
    );
  }

  /// v5 機能 A: 機種選択 chips（「未指定」= null + availableGameVersions）。
  ///
  /// WHY 全入口共通・先頭配置: 機種は「どの入力導線でも同じ値を添えたい」ため、
  /// 行の一番上に置き選択状態をシート全体で共有する。value ベースでなく
  /// index ベースの ValueKey（`species-machine-chip-<index>`）なのは、機種名の
  /// リネーム（商標対応含む）でテスト key を壊さないようにする設計 §2 と同じ方針。
  Widget _machineChipRow(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('機種', style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              ChoiceChip(
                key: const ValueKey<String>('species-machine-chip-none'),
                label: const Text('未指定'),
                selected: _machine == null,
                onSelected: (_) => setState(() => _machine = null),
              ),
              ...List<Widget>.generate(
                availableGameVersions.length,
                (int index) => ChoiceChip(
                  key: ValueKey<String>('species-machine-chip-$index'),
                  label: Text(availableGameVersions[index]),
                  selected: _machine == availableGameVersions[index],
                  onSelected: (_) =>
                      setState(() => _machine = availableGameVersions[index]),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 「HC プレーシェア」行（ギャラリー pick → hint=hcV1）。
  Widget _playShareRow(BuildContext context) {
    return ListTile(
      key: const ValueKey<String>('species-row-playshare'),
      title: const Text('HC プレーシェア'),
      subtitle: const Text('共有画像（プレイ結果シェア画面）から読み取る'),
      onTap: () => _closeAnd(context, widget.onPickPlayShare),
    );
  }

  /// 「HC リザルト写真」親行と 2 アクション。
  ///
  /// FR-9 カメラ撮影入口: Android でのみカメラピッカーを表示、
  /// その他プラットフォームではギャラリーのみとなる。
  List<Widget> _resultRows(BuildContext context) {
    return <Widget>[
      const ListTile(
        key: ValueKey<String>('species-row-result'),
        title: Text('HC リザルト写真'),
        subtitle: Text('アーケード実機のリザルト画面写真から読み取る'),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Column(
          children: <Widget>[
            ListTile(
              key: ValueKey<String>('species-row-result-gallery'),
              title: const Text('ギャラリーから選択'),
              onTap: () => _closeAnd(context, widget.onPickResultGallery),
            ),
            // Androidのみカメラアクションを表示（platform gate）
            if (_cameraVisible(context))
              ListTile(
                key: ValueKey<String>('species-row-result-camera'),
                title: const Text('カメラで撮影'),
                subtitle: const Text('リザルト画面全体が収まるように撮影してください'),
                onTap: () => _closeAnd(context, widget.onPickResultCamera),
              ),
          ],
        ),
      ),
    ];
  }

  /// 「写真なしで手入力」行（v4 案2・docs/v4_manual_entry_design_2026-11-23.md §2.1）。
  ///
  /// WHY: 実機写真の OCR が現状苦手なため、写真を使わず数値を直接入力して
  /// 確定保存できる動線を用意する。機種が選ばれていれば初期値として添える。
  Widget _manualEntryRow(BuildContext context) {
    return ListTile(
      key: const ValueKey<String>('species-row-manual-entry'),
      title: const Text('写真なしで手入力'),
      subtitle: const Text('写真を使わずスコアなどの数値を直接入力します'),
      onTap: () => _closeAnd(context, widget.onManualEntry),
    );
  }

  /// 「Lively」親行と 2 アクション（PC 版 Lively のスコア画面写真）。
  ///
  /// WHY 有効化（2026-11-24）: 統合ストラテジー（2 倍パネル + 行ブロック 3 パス）
  /// を本番経路に載せ、H&C と同じ確認・登録フローに合流できるようにした。
  ///
  /// WHY 2 アクションを常時表示（2026-11-26 のユーザー指示「HC のカメラで撮影の
  /// ようにその場で枠線付きのカメラを起動することはできますか」）: HC リザルト写真と
  /// 同じ形にそろえる。保存済み画像が無い場面（PC の前で撮りたい場面）でも取り込める。
  /// 開閉アニメーションを挟まないのは HC 側と同じ理由（操作ステップを増やさない）。
  ///
  /// WHY 機種を [livelyMachineName] に固定するか（2026-11-26 のユーザー指示
  /// 「Lively のスコア画面写真から読み取るを選んで OCR を始めた場合は編集画面でも
  /// Lively を自動で選択していてほしい」）: この行が読むのは PC 版 Lively の
  /// スコア画面だけで、機種は必ず Lively に決まる。chip の選択（既定 H☆C!!）を
  /// そのまま添えると、選び忘れで H☆C!! の記録として保存されてしまう。
  /// 行の選択自体が機種の指定を兼ねる。
  List<Widget> _livelyRows(BuildContext context) {
    return <Widget>[
      const ListTile(
        key: ValueKey<String>('species-row-lively'),
        title: Text('Lively'),
        subtitle: Text('PC 版 Lively のスコア画面写真から読み取る'),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Column(
          children: <Widget>[
            ListTile(
              key: const ValueKey<String>('species-row-lively-gallery'),
              title: const Text('ギャラリーから選択'),
              onTap: () => _closeAnd(
                context,
                widget.onPickLivelyGallery,
                machineOverride: livelyMachineName,
              ),
            ),
            // Androidのみカメラアクションを表示（platform gate・HC 側と同一条件）
            if (_cameraVisible(context))
              ListTile(
                key: const ValueKey<String>('species-row-lively-camera'),
                title: const Text('カメラで撮影'),
                subtitle: const Text('スコア画面が枠に収まるように撮影してください'),
                onTap: () => _closeAnd(
                  context,
                  widget.onPickLivelyCamera,
                  machineOverride: livelyMachineName,
                ),
              ),
          ],
        ),
      ),
    ];
  }
}
