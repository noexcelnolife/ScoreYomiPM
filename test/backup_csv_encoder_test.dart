// バックアップ CSV エンコーダのホストテスト（タスク 01a20bfe・データ層）。
//
// WHY: CSV は Excel 等の外部ツールで開く前提のため、BOM 付き UTF-8・CRLF・
// RFC4180 の引用規則を仕様として固定する。列順は仕様書の並びに従う。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:scoreyomipm/backup/backup_csv_encoder.dart';
import 'package:scoreyomipm/data/play_record.dart';

PlayRecord buildRecord({
  String? songName = 'テスト曲',
  String? clearMedal = 'フルコンボ',
  GameDifficulty? difficulty = GameDifficulty.hyper,
  String? machine = 'H☆C!!',
  PlayRecordStatus status = PlayRecordStatus.confirmed,
  int? level = 44,
  String? memo,
}) {
  return PlayRecord(
    id: 'r1',
    playedAt: DateTime(2026, 11, 23, 21, 5),
    songName: songName,
    score: 98108,
    cool: 975,
    great: 58,
    good: 2,
    bad: 1,
    maxCombo: 733,
    level: level,
    clearMedal: clearMedal,
    difficulty: difficulty,
    machine: machine,
    memo: memo,
    status: status,
    source: PlayRecordSource.playshare,
    resultImagePath: '',
  );
}

void main() {
  const BackupCsvEncoder encoder = BackupCsvEncoder();

  test('ヘッダ行は仕様の列順のまま出力される', () {
    final String csv = encoder.encode(<PlayRecord>[buildRecord()]);
    final List<String> lines = csv.split('\r\n');

    expect(
      lines.first.replaceFirst('\uFEFF', ''),
      '実施日時,曲名,難易度,レベル,スコア,COOL,GREAT,GOOD,BAD,MAX COMBO,クリアメダル,機種,状態,記録元,メモ',
    );
  });

  test('先頭に UTF-8 BOM が付き、改行は CRLF になる', () {
    final String csv = encoder.encode(<PlayRecord>[buildRecord()]);
    final List<int> bytes = utf8.encode(csv);

    // WHY: BOM が無いと Excel が cp932 と誤認して日本語が化ける。
    expect(bytes.take(3).toList(), <int>[0xEF, 0xBB, 0xBF]);
    expect(csv.contains('\r\n'), isTrue);
    // 単独 LF（CRLF でない改行）が混ざらないこと。
    expect(RegExp(r'(?<!\r)\n').hasMatch(csv), isFalse);
  });

  test('0 件でも BOM + ヘッダ 1 行だけを出力する', () {
    final String csv = encoder.encode(<PlayRecord>[]);

    expect(csv.startsWith('\uFEFF'), isTrue);
    expect(csv.split('\r\n').length, 2); // ヘッダ + 末尾の空文字
  });

  test('値の並びがヘッダの列順と一致する', () {
    final String csv = encoder.encode(<PlayRecord>[buildRecord()]);
    final List<String> cells = csv.split('\r\n')[1].split(',');

    expect(cells[0], '2026-11-23 21:05');
    expect(cells[1], 'テスト曲');
    expect(cells[2], 'HYPER');
    expect(cells[3], '44');
    expect(cells[4], '98108');
    expect(cells[5], '975');
    expect(cells[6], '58');
    expect(cells[7], '2');
    expect(cells[8], '1');
    expect(cells[9], '733');
    expect(cells[10], 'フルコンボ');
    expect(cells[11], 'H☆C!!');
    expect(cells[12], '確定');
    expect(cells[13], 'プレーシェア');
    expect(cells[14], '');
  });

  test('メモは末尾の列に出力され、改行を含んでも引用符で保持される', () {
    final String csv = encoder.encode(<PlayRecord>[
      buildRecord(memo: '精度重視\nBP 更新'),
    ]);

    // 記録元（14 列目）の直後＝最終列にメモが来ること。
    expect(csv, contains('プレーシェア,"精度重視\nBP 更新"'));
  });

  test('null は空文字列として出力する', () {
    final String csv = encoder.encode(<PlayRecord>[
      buildRecord(
        songName: null,
        clearMedal: null,
        difficulty: null,
        machine: null,
        level: null,
      ),
    ]);
    final List<String> cells = csv.split('\r\n')[1].split(',');

    expect(cells[1], '');
    expect(cells[2], '');
    expect(cells[3], '');
    expect(cells[10], '');
    expect(cells[11], '');
  });

  test('カンマを含む値は全体を引用符で囲む', () {
    final String csv = encoder.encode(<PlayRecord>[
      buildRecord(songName: 'ア, イ'),
    ]);

    expect(csv, contains('"ア, イ"'));
  });

  test('引用符を含む値は二重引用符でエスケープする', () {
    final String csv = encoder.encode(<PlayRecord>[
      buildRecord(songName: 'a"b'),
    ]);

    expect(csv, contains('"a""b"'));
  });

  test('改行を含む値は引用符で囲んでそのまま保持する', () {
    final String csv = encoder.encode(<PlayRecord>[
      buildRecord(songName: 'a\nb'),
    ]);

    expect(csv, contains('"a\nb"'));
  });

  test('難易度は enum 名の大文字表記になる（UI 表示と同表記）', () {
    for (final GameDifficulty difficulty in GameDifficulty.values) {
      final String csv = encoder.encode(<PlayRecord>[
        buildRecord(difficulty: difficulty),
      ]);
      expect(csv.split('\r\n')[1].split(',')[2], difficulty.name.toUpperCase());
    }
  });

  test('状態は日本語ラベルになる', () {
    final String pending = encoder.encode(<PlayRecord>[
      buildRecord(status: PlayRecordStatus.pending),
    ]);
    final String confirmed = encoder.encode(<PlayRecord>[
      buildRecord(status: PlayRecordStatus.confirmed),
    ]);

    expect(pending.split('\r\n')[1].split(',')[12], '未確定');
    expect(confirmed.split('\r\n')[1].split(',')[12], '確定');
  });
}
