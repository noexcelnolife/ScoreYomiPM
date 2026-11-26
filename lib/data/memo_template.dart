// メモ入力のプリセット（テンプレート）のデータモデル。
//
// WHY: 記録ごとのメモは毎回ゼロから書くと手間がかかる。よく使う文面を
// 名前付きで保存しておき、入力画面から 1 タップで差し込めるようにする。
// テンプレートは「入力の補助」に限定し、記録側（PlayRecord.memo）には
// 展開済みの本文だけを保存する。したがってテンプレートを削除しても、
// 既に書いたメモは影響を受けない。

/// メモのプリセット。
///
/// [title] は一覧で見分けるための短い名前、[body] が実際にメモへ差し込まれる本文。
class MemoTemplate {
  const MemoTemplate({
    required this.id,
    required this.title,
    required this.body,
  });

  /// タイトルの最大文字数。
  ///
  /// WHY 上限を設けるか: 一覧の 1 行に収まらない長さの名前は見分けに使えず、
  /// 入力の手間だけが増えるため。
  static const int titleMaxLength = 40;

  /// 本文の最大文字数（メモ本体の入力上限と揃える）。
  static const int bodyMaxLength = 2000;

  /// 識別子（保存時にリポジトリが発行する）。
  final String id;

  /// 一覧に表示する短い名前。
  final String title;

  /// メモへ差し込む本文。
  final String body;

  /// タイトルと本文を差し替えた複製を返す。
  MemoTemplate copyWith({String? title, String? body}) {
    return MemoTemplate(
      id: id,
      title: title ?? this.title,
      body: body ?? this.body,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'id': id, 'title': title, 'body': body};
  }

  /// JSON から復元する。
  ///
  /// 必須項目が欠けている場合は [FormatException] を投げる。壊れた 1 件で
  /// 一覧全体を失わないよう、呼び出し側（リポジトリ）がこの例外を捕まえて
  /// その 1 件だけ捨てる契約にしている。
  factory MemoTemplate.fromJson(Map<String, dynamic> json) {
    final String id = (json['id'] as String? ?? '').trim();
    final String title = (json['title'] as String? ?? '').trim();
    final String body = (json['body'] as String? ?? '').trim();
    if (id.isEmpty || title.isEmpty || body.isEmpty) {
      throw const FormatException('メモテンプレートの必須項目が欠けている');
    }
    return MemoTemplate(id: id, title: title, body: body);
  }

  /// タイトルの入力検証（問題なければ null）。
  static String? validateTitle(String? raw) {
    final String value = (raw ?? '').trim();
    if (value.isEmpty) {
      return '名前を入力してください';
    }
    if (value.length > titleMaxLength) {
      return '名前は$titleMaxLength文字以内で入力してください';
    }
    return null;
  }

  /// 本文の入力検証（問題なければ null）。
  static String? validateBody(String? raw) {
    final String value = (raw ?? '').trim();
    if (value.isEmpty) {
      return '本文を入力してください';
    }
    if (value.length > bodyMaxLength) {
      return '本文は$bodyMaxLength文字以内で入力してください';
    }
    return null;
  }

  @override
  String toString() => 'MemoTemplate(id: $id, title: $title)';
}
