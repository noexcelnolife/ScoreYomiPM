// テスト用のメモテンプレートリポジトリ（メモリ内・ファイル I/O なし）。
import 'package:scoreyomipm/data/memo_template.dart';
import 'package:scoreyomipm/data/memo_template_repository.dart';

/// メモリ上だけで動く [MemoTemplateRepository]。
///
/// WHY: UI テストの検証対象は「一覧の出し方と差し込み結果」であり、永続化の
/// 正しさは memo_template_repository_test.dart 側で実ファイルを相手に検証する。
class FakeMemoTemplateRepository implements MemoTemplateRepository {
  FakeMemoTemplateRepository([List<MemoTemplate> seed = const <MemoTemplate>[]])
    : _templates = List<MemoTemplate>.of(seed);

  final List<MemoTemplate> _templates;
  int _sequence = 0;

  /// add が呼ばれた回数（差し込みだけで保存されていないことの確認に使う）。
  int addCount = 0;

  @override
  Future<List<MemoTemplate>> listAll() async {
    return List<MemoTemplate>.unmodifiable(_templates);
  }

  @override
  Future<MemoTemplate> add({
    required String title,
    required String body,
  }) async {
    addCount++;
    final MemoTemplate template = MemoTemplate(
      id: 'fake-${++_sequence}',
      title: title.trim(),
      body: body.trim(),
    );
    _templates.add(template);
    return template;
  }

  @override
  Future<MemoTemplate> update(MemoTemplate template) async {
    final int index = _templates.indexWhere(
      (MemoTemplate item) => item.id == template.id,
    );
    if (index < 0) {
      throw StateError('未知のメモテンプレート id: ${template.id}');
    }
    _templates[index] = template;
    return template;
  }

  @override
  Future<void> delete(String id) async {
    _templates.removeWhere((MemoTemplate item) => item.id == id);
  }

  @override
  Future<int> mergeAll(List<MemoTemplate> templates) async {
    final Set<String> existingIds = <String>{
      for (final MemoTemplate item in _templates) item.id,
    };
    int added = 0;
    for (final MemoTemplate item in templates) {
      if (!existingIds.add(item.id)) continue;
      _templates.add(item);
      added++;
    }
    return added;
  }
}
