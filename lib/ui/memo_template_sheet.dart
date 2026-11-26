// メモのテンプレート（プリセット）操作用のシート。
//
// 役割は 2 つ:
// 1. 保存済みテンプレートを一覧し、選んだ本文を呼び出し元へ返す
// 2. テンプレートの追加・編集・削除（この画面で完結させる）
//
// WHY 一覧と管理を同じシートに置くか: テンプレートは「メモを書いている最中」に
// 作ったり直したりしたくなる。別画面へ遷移させると入力中のメモ（と未保存の
// フォーム）から離れることになり、戻ってきたときの文脈復帰コストが高い。
import 'package:material_ui/material_ui.dart';

import '../data/memo_template.dart';
import '../data/memo_template_repository.dart';

/// テンプレート選択シートを開き、選ばれた本文を返す（未選択・閉じた場合は null）。
Future<String?> showMemoTemplateSheet({
  required BuildContext context,
  required MemoTemplateRepository repository,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) =>
        MemoTemplateSheet(repository: repository),
  );
}

/// テンプレートの一覧・管理シート本体。
class MemoTemplateSheet extends StatefulWidget {
  const MemoTemplateSheet({super.key, required this.repository});

  /// テンプレートの永続化先。
  final MemoTemplateRepository repository;

  @override
  State<MemoTemplateSheet> createState() => _MemoTemplateSheetState();
}

class _MemoTemplateSheetState extends State<MemoTemplateSheet> {
  /// 読み込み中のテンプレート。null は「まだ読み込んでいない」。
  List<MemoTemplate>? _templates;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 一覧を読み直す（追加・編集・削除の後に呼ぶ）。
  Future<void> _reload() async {
    final List<MemoTemplate> templates = await widget.repository.listAll();
    if (!mounted) {
      return;
    }
    setState(() => _templates = templates);
  }

  /// 新規テンプレートを追加する。
  Future<void> _addTemplate() async {
    final ({String title, String body})? input =
        await showDialog<({String title, String body})>(
          context: context,
          builder: (BuildContext dialogContext) =>
              const _TemplateEditorDialog(),
        );
    if (input == null) {
      return;
    }
    await widget.repository.add(title: input.title, body: input.body);
    await _reload();
  }

  /// 既存テンプレートを編集する。
  Future<void> _editTemplate(MemoTemplate template) async {
    final ({String title, String body})? input =
        await showDialog<({String title, String body})>(
          context: context,
          builder: (BuildContext dialogContext) =>
              _TemplateEditorDialog(initial: template),
        );
    if (input == null) {
      return;
    }
    await widget.repository.update(
      template.copyWith(title: input.title, body: input.body),
    );
    await _reload();
  }

  /// テンプレートを削除する（確認あり）。
  ///
  /// WHY 確認を挟むか: テンプレートは作り直しに手間がかかるうえ、メモ入力中の
  /// 一覧から 1 タップで消えるのは取り返しがつきにくい。
  Future<void> _deleteTemplate(MemoTemplate template) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('テンプレートを削除'),
        content: Text('「${template.title}」を削除します。よろしいですか？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await widget.repository.delete(template.id);
    await _reload();
  }

  /// 選んだテンプレートの本文を返してシートを閉じる。
  void _select(MemoTemplate template) {
    Navigator.of(context).pop(template.body);
  }

  @override
  Widget build(BuildContext context) {
    final List<MemoTemplate>? templates = _templates;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('メモのテンプレート', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (templates == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (templates.isEmpty)
              const _EmptyTemplatesView()
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: templates.length,
                  itemBuilder: (BuildContext listContext, int index) {
                    final MemoTemplate template = templates[index];
                    return _TemplateTile(
                      template: template,
                      onTap: () => _select(template),
                      onEdit: () => _editTemplate(template),
                      onDelete: () => _deleteTemplate(template),
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _addTemplate,
              icon: const Icon(Icons.add),
              label: const Text('テンプレートを追加'),
            ),
          ],
        ),
      ),
    );
  }
}

/// テンプレート 1 件分の行（タップで差し込み、右端で編集・削除）。
class _TemplateTile extends StatelessWidget {
  const _TemplateTile({
    required this.template,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final MemoTemplate template;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      title: Text(template.title),
      // WHY 本文を 2 行で切るか: 一覧は「どれを差し込むか」を選ぶ場所なので、
      // 全文を出すと 1 件で画面が埋まり比較できなくなる。全文は編集で確認できる。
      subtitle: Text(
        template.body,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined),
            tooltip: '編集',
          ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
            tooltip: '削除',
          ),
        ],
      ),
    );
  }
}

/// テンプレートが 1 件も無いときの案内。
class _EmptyTemplatesView extends StatelessWidget {
  const _EmptyTemplatesView();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: <Widget>[
          Text('テンプレートがありません', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            'よく使う文面を登録しておくと、メモ入力時に 1 タップで差し込めます。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// テンプレートの新規作成・編集ダイアログ。
///
/// 保存時に入力値を返すだけで、永続化は呼び出し側（シート）が行う
/// （ダイアログは表示と入力検証に専念させる）。
class _TemplateEditorDialog extends StatefulWidget {
  const _TemplateEditorDialog({this.initial});

  /// 編集対象（新規作成時は null）。
  final MemoTemplate? initial;

  @override
  State<_TemplateEditorDialog> createState() => _TemplateEditorDialogState();
}

class _TemplateEditorDialogState extends State<_TemplateEditorDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController = TextEditingController(
    text: widget.initial?.title ?? '',
  );
  late final TextEditingController _bodyController = TextEditingController(
    text: widget.initial?.body ?? '',
  );

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  /// 入力値が妥当なら結果を返して閉じる。
  void _submit() {
    if (_formKey.currentState?.validate() != true) {
      return;
    }
    Navigator.of(context).pop((
      title: _titleController.text.trim(),
      body: _bodyController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bool isEditing = widget.initial != null;
    return AlertDialog(
      title: Text(isEditing ? 'テンプレートを編集' : 'テンプレートを追加'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextFormField(
                controller: _titleController,
                maxLength: MemoTemplate.titleMaxLength,
                decoration: const InputDecoration(
                  labelText: '名前',
                  hintText: '例: 精度重視',
                ),
                validator: MemoTemplate.validateTitle,
              ),
              TextFormField(
                controller: _bodyController,
                maxLength: MemoTemplate.bodyMaxLength,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '本文',
                  hintText: 'メモに差し込む文章',
                  alignLabelWithHint: true,
                ),
                validator: MemoTemplate.validateBody,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
