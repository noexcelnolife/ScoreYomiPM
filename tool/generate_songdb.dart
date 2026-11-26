/// 収録曲 DB 生成スクリプト（タスク 01a20201・tool/songdb パイプラインのエントリポイント）。
///
/// H☆C!! 旧曲リスト/新曲リストを取得し、
/// wiki_sections.extractTables → SongDbBuilder.build() で SongEntry 互換 JSON を
/// 配信 DB 第1版 `db/popn_hc_main_v1.json` として書き出す（dbVersion 1）。
///
/// 実行方法（リポジトリルートで）:
///   dart run tool/generate_songdb.dart            # cache-first（tool/data/ にキャッシュがあれば使用）
///   dart run tool/generate_songdb.dart --refresh  # wiki を再取得してキャッシュ更新
///
/// リード決定事項（2026-11-22）への対応:
/// - seed_v1.json は据え置き（33 曲・オフラインフォールバックのまま。本スクリプトは触らない）
/// - エンベロープ契約キー厳守 {schemaVersion, dbVersion, updatedAt, sourceType, songCount, songs}
/// - 取得は dart:io HttpClient 直取得（案A。IPv6 優先環境でも実測成功 — curl.exe は -4 が
///   必要だったが Dart は失敗しなかった。フォールバック案の curl.exe -4 サブプロセスは未実装）
/// - デコード自己検証: charset 確認 + 既知日本語部分文字列の存在チェック
/// - 生 HTML は tool/data/（.gitignore 済）にキャッシュ。メタ情報は
///   tool/songdb_manifest.json（URL・取得日時・バイト数・sha256）をコミット
/// - 検証はファイル経由（build ログを tool/data/build_log_latest.txt にも書き出す）
///
/// 出力フォーマットは test/seed_data_consistency_test.dart と同一規約
/// （docs/song_db_design_confirmation_report_2026-11-22.md §5・§9）。
/// - levels は疎マップ（null を入れない。SongEntry.fromJson が null をレベル 0 に
///   変換するため。songdb_builder.dart _entryJson の WHY コメント参照）
///
/// ハードゲート: id 重複・セクション欠落時は SongDbBuildException で異常終了し、
/// 出力ファイルは更新しない（壊れた DB をコミットさせない）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'songdb/songdb_builder.dart';
import 'songdb/wiki_sections.dart';

/// 旧曲リスト（AC/CS/ee'MALL セクションを含む）。
const String oldListUrl =
    "https://bemaniwiki.com/index.php?pop%27n+music+High%E2%98%86Cheers%21%21/%E6%97%A7%E6%9B%B2%E3%83%AA%E3%82%B9%E3%83%88";

/// 新曲リスト（楽曲リスト表 + キャラ・総ノーツ数表）。
const String newListUrl =
    "https://bemaniwiki.com/index.php?pop%27n+music+High%E2%98%86Cheers%21%21/%E6%96%B0%E6%9B%B2%E3%83%AA%E3%82%B9%E3%83%88";

/// 配信 DB 第1版の出力先（タスク 01a20201 の推奨配置）。
const String outputPath = 'db/popn_hc_main_v1.json';

/// マニフェスト（コミット対象・取得元の証跡）。
const String manifestPath = 'tool/songdb_manifest.json';

/// 生 HTML キャッシュ・ログの出力先（.gitignore 対象）。
const String cacheDirPath = 'tool/data';

/// ソースキー → (URL, キャッシュファイル名, デコード自己検証用の既知部分文字列)。
const Map<String, List<String>> sources = <String, List<String>>{
  'oldList': [oldListUrl, 'old_list.html', '旧曲リスト'],
  'newList': [newListUrl, 'new_list.html', '新曲リスト'],
};

/// ページ本文を UTF-8 で取得し、デコード自己検証を通す。
///
/// WHY: bemaniwiki の Content-Type は charset=UTF-8 確認済み（2026-11-22）のため
/// dart:convert の utf8 で十分。万一 EUC-JP 等が出ても charset 検証で失敗させ、
/// 文字化け JSON を書き出さない。既知日本語部分文字列チェックは charset 欺瞞
/// （UTF-8 別名や誤ヘッダ）への第 2 防線。
Future<String> fetchPage(
  HttpClient client,
  String url,
  String knownText,
) async {
  final request = await client.getUrl(Uri.parse(url));
  request.headers.set(
    HttpHeaders.userAgentHeader,
    'PMscoreman-songdb-builder/1.0 (flutter app db generator)',
  );
  final response = await request.close();
  final charset = response.headers.contentType?.charset;
  if (charset != null && charset.toLowerCase() != 'utf-8') {
    throw SongDbBuildException('想定外の charset=$charset: $url');
  }
  if (response.statusCode != HttpStatus.ok) {
    throw SongDbBuildException('HTTP ${response.statusCode}: $url');
  }
  final body = await utf8.decoder.bind(response).join();
  if (!body.contains(knownText)) {
    throw SongDbBuildException('デコード自己検証失敗（既知文字列 "$knownText" 不在）: $url');
  }
  return body;
}

/// キャッシュを優先して本文を用意する（cache-first / --refresh で再取得）。
///
/// WHY: fetchedAt はマニフェストの取得日時証跡のため、実際に取得したときだけ
/// 記録する（キャッシュヒット時は前回の実取得日時を保持したままにする）。
Future<Map<String, String>> loadPages(
  HttpClient client,
  bool refresh,
  List<String> log,
  Map<String, DateTime> fetchedAt,
) async {
  final cacheDir = Directory(cacheDirPath);
  if (!cacheDir.existsSync()) {
    cacheDir.createSync(recursive: true);
  }
  final pages = <String, String>{};
  for (final entry in sources.entries) {
    final key = entry.key;
    final url = entry.value[0];
    final cacheFile = File('${cacheDir.path}/${entry.value[1]}');
    final knownText = entry.value[2];
    final useCache =
        !refresh && cacheFile.existsSync() && cacheFile.lengthSync() > 10000;
    if (useCache) {
      final cached = cacheFile.readAsStringSync(encoding: utf8);
      // WHY: キャッシュもデコード自己検証を通す（破損キャッシュの混入防止）。
      if (cached.contains(knownText)) {
        pages[key] = cached;
        log.add(
          '[CACHE] $key=${cacheFile.path} (${cacheFile.lengthSync()} bytes)',
        );
        continue;
      }
      log.add('[CACHE] $key のキャッシュが破損しているため再取得します');
    }
    log.add('[FETCH] $key: $url');
    final fetched = DateTime.now().toUtc();
    final body = await fetchPage(client, url, knownText);
    cacheFile.writeAsStringSync(body, encoding: utf8);
    pages[key] = body;
    fetchedAt[key] = fetched;
    log.add('[FETCH] $key=${body.length} 文字');
  }
  return pages;
}

/// マニフェスト（URL・取得日時・バイト数・sha256）を書き出す。
Future<void> writeManifest(
  Map<String, String> pages,
  Map<String, DateTime> fetchedAt,
  File outputFile,
) async {
  final sourcesJson = <Map<String, Object?>>[];
  for (final entry in sources.entries) {
    final key = entry.key;
    final bytes = utf8.encode(pages[key]!);
    sourcesJson.add(<String, Object?>{
      'key': key,
      'url': entry.value[0],
      'fetchedAt': (fetchedAt[key] ?? DateTime.now().toUtc()).toIso8601String(),
      'byteCount': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  }
  final outputBytes = await outputFile.readAsBytes();
  final manifest = <String, Object?>{
    'output': <String, Object?>{
      'path': outputPath,
      'byteCount': outputBytes.length,
      'sha256': sha256.convert(outputBytes).toString(),
    },
    'sources': sourcesJson,
    'generator': 'tool/generate_songdb.dart',
  };
  const encoder = JsonEncoder.withIndent('  ');
  await File(manifestPath)
      .writeAsString('${encoder.convert(manifest)}\n', encoding: utf8);
}

Future<void> main(List<String> args) async {
  final refresh = args.contains('--refresh');
  final log = <String>[];
  try {
    final client = HttpClient();
    final fetchedAt = <String, DateTime>{};
    Map<String, String> pages;
    try {
      pages = await loadPages(client, refresh, log, fetchedAt);
    } finally {
      client.close();
    }

    // WHY: 2 ページを extractTables に個別に通す（ページ境界をまたぐ誤判定を防ぐ）。
    final tables = <WikiTable>[
      ...extractTables(pages['oldList']!),
      ...extractTables(pages['newList']!),
    ];
    for (final table in tables) {
      log.add(
        '[TABLE] section=${table.sectionKey} heading=${table.heading} rows=${table.rawRows.length}',
      );
    }

    final builder = SongDbBuilder(tables);
    final songs = builder.build();
    log.addAll(builder.log.lines);

    final output = <String, Object?>{
      'schemaVersion': 1,
      'dbVersion': 1,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      // WHY: ユーザー指示（2026-11-25）により sourceType は wikiHC。取得元を表す値に
      //   サイト名と機種名の綴りを残さない（旧値はこの 1 語で、すでに置き換え済み）。
      //   取得元の URL は bemaniwiki の H☆C!! 旧曲/新曲リストのまま（外部リソースの識別子）。
      'sourceType': 'wikiHC',
      'songCount': songs.length,
      'songs': songs,
    };
    const encoder = JsonEncoder.withIndent('  ');
    final file = File(outputPath);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsString('${encoder.convert(output)}\n', encoding: utf8);
    log.add('[DONE] ${file.path} に ${songs.length} 件を書き出しました');

    await writeManifest(pages, fetchedAt, file);
    log.add('[DONE] $manifestPath を書き出しました');
  } on SongDbBuildException catch (e) {
    log.add('[ERROR] $e');
    final cacheDir = Directory(cacheDirPath);
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }
    File('$cacheDirPath/build_log_latest.txt')
        .writeAsStringSync('${log.join('\n')}\n', encoding: utf8);
    stderr.writeln(e.toString());
    exitCode = 1;
    return;
  }
  // 成功時も検証用にファイルへ残す（stdout の日本語は PS5.1 で崩れ得るため）。
  Directory(cacheDirPath).createSync(recursive: true);
  File('$cacheDirPath/build_log_latest.txt')
      .writeAsStringSync('${log.join('\n')}\n', encoding: utf8);
  for (final line in log) {
    stdout.writeln(line);
  }
}
