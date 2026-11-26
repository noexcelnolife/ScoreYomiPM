// kAppVersion 定数と pubspec.yaml の版ずれを検出するテスト（タスク 01a20c14）。
//
// WHY: バックアップ manifest に記録する版は package_info_plus ではなく定数で持つ
//（ビルド手順を増やさない方針・リード裁定）。手動同期でも更新漏れが起きるため、
// pubspec.yaml の version 行と一致することをテストで機械的に検証する。
//
// WHY(期待値をリテラルで書かない): 版は 1.4.0+6 → 1.5.0+7 のように上がる。
// 定数の値を固定すると版上げのたびにテストを書き換えることになるので、
// 「定数 == pubspec」だけを保証する（リード指示 2026-11-24）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:scoreyomipm/app_info.dart';

void main() {
  test('kAppVersion は pubspec.yaml の version と一致する', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    final RegExpMatch? match = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull, reason: 'pubspec.yaml に version: 行が必要');
    expect(
      kAppVersion,
      match!.group(1),
      reason: 'lib/app_info.dart の kAppVersion を pubspec.yaml に合わせて更新する',
    );
  });
}
