import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// このオリジンの保存領域を「永続」へ昇格するようブラウザへ要求する。
///
/// WHY(要求するか): IndexedDB は既定で「ベストエフォート」に分類され、空き容量が
/// 逼迫するとブラウザがオリジン単位で丸ごと削除できる。プレイ記録と原画像は
/// 利用者が再生成できない入力なので、削除対象から外れるよう要求しておく。
///
/// WHY(結果を捨てるか): 許可はブラウザの裁量（Firefox は利用者の操作履歴、
/// Chrome はインストール状況などで自動判定）で、拒否されても保存は成立する。
/// 呼び出し側の保存処理を止める理由が無いため、成否は戻り値として返すだけにし、
/// 例外は投げない。
Future<bool> requestPersistentStorage() async {
  try {
    final web.StorageManager storage = web.window.navigator.storage;
    // WHY(persisted を先に見るか): 既に昇格済みなら persist() は即座に true を
    // 返すが、呼ぶたびにブラウザ側の判定履歴に触れる。無駄な問い合わせを避ける。
    if ((await storage.persisted().toDart).toDart) {
      return true;
    }
    return (await storage.persist().toDart).toDart;
  } on Object {
    // WHY(握り潰すか): 非対応ブラウザ（StorageManager が無い）や権限ポリシーで
    // 拒否されたケース。保存自体は成立しているので、ここで失敗にしない。
    return false;
  }
}
