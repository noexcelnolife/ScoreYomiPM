// Web 版の配布物を作る唯一の手順。
//
// WHY スクリプトにするか: Web ビルドは 3 つの前提を同時に満たさないと壊れる。
//   1. OCR 資産が web/ocr_vendor/ に無いと OCR が動かない（D-W16 により追跡外）
//   2. --base-href を付けないと GitHub Pages のサブパスで真っ白になる（D-W1）
//   3. --no-web-resources-cdn を付けないと CanvasKit を gstatic から取る
//      （オフライン動作と「外部送信なし」の基準を満たさない）
// 手順を人の記憶に任せると 1 つ落ちる。1 本にまとめて落ちないようにする。
//
// 使い方:
//   node tool/build_web.mjs                                  # ローカル確認用（base href は /）
//   node tool/build_web.mjs --base-href /ScoreYomiPM/        # GitHub Pages 用
//   node tool/build_web.mjs --skip-ocr                       # OCR 資産を作り直さない
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');
const buildDir = join(repoRoot, 'build', 'web');

/** 版の指紋を作る対象。ここが変われば Service Worker のキャッシュ名が変わる。 */
const VERSION_FINGERPRINT_FILES = ['main.dart.js', 'index.html', 'flutter_bootstrap.js', 'manifest.json'];

/** 既定の Flutter 実体。PATH に無い環境（このリポジトリの開発機）を考慮する。 */
const FLUTTER = process.env.FLUTTER ?? 'C:\\dev\\flutter\\bin\\flutter.bat';

function parseArgs(argv) {
  const options = { baseHref: '/', skipOcr: false };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--base-href') {
      options.baseHref = argv[i + 1];
      i += 1;
    } else if (argv[i] === '--skip-ocr') {
      options.skipOcr = true;
    } else if (argv[i] === '--help' || argv[i] === '-h') {
      process.stdout.write('node tool/build_web.mjs [--base-href /path/] [--skip-ocr]\n');
      process.exit(0);
    } else {
      throw new Error(`不明な引数: ${argv[i]}`);
    }
  }
  if (!options.baseHref.startsWith('/') || !options.baseHref.endsWith('/')) {
    throw new Error(`--base-href は / で始まり / で終わる必要がある: ${options.baseHref}`);
  }
  return options;
}

function run(command, args) {
  // .bat は shell 経由でないと起動できない。shell: true は引数をエスケープせず連結するため
  // （Node の DEP0190）、cmd.exe を明示的に挟んで警告を出さずに済ませる。
  const isBatch = process.platform === 'win32' && /\.(bat|cmd)$/i.test(command);
  if (isBatch) {
    execFileSync(process.env.ComSpec ?? 'cmd.exe', ['/d', '/c', command, ...args], {
      cwd: repoRoot,
      stdio: 'inherit',
    });
    return;
  }
  execFileSync(command, args, { cwd: repoRoot, stdio: 'inherit' });
}

function totalBytes(dir) {
  let total = 0;
  const walk = (current) => {
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const full = join(current, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else {
        total += statSync(full).size;
      }
    }
  };
  walk(dir);
  return total;
}

/** ビルド後に「外部に取りに行っていない」ことを静的に確かめる。 */
function verifyNoCdn() {
  const problems = [];
  const bootstrap = join(buildDir, 'flutter_bootstrap.js');
  if (!existsSync(join(buildDir, 'canvaskit'))) {
    problems.push('build/web/canvaskit が無い（--no-web-resources-cdn が効いていない可能性）');
  }
  if (existsSync(bootstrap)) {
    const text = readFileSync(bootstrap, 'utf8');
    // gstatic の URL 自体は常に定数として埋め込まれる。判定に使えるのはこのフラグで、
    // ローダーは `useLocalCanvasKit` が true のときだけ自前配信の canvaskit/ を選ぶ。
    if (!text.includes('"useLocalCanvasKit":true')) {
      problems.push('flutter_bootstrap.js が CanvasKit を自前配信にしていない（--no-web-resources-cdn が効いていない）');
    }
  } else {
    problems.push('flutter_bootstrap.js が無い');
  }
  const ocr = join(buildDir, 'ocr_vendor');
  if (!existsSync(ocr)) {
    problems.push('build/web/ocr_vendor が無い（OCR 資産が配布物に入っていない）');
  }
  return problems;
}

/**
 * version.json を書く。
 *
 * WHY(内容ハッシュか): Service Worker はこの版をキャッシュ名に使い、変わったときだけ
 * 殻を差し替える。日時だと中身が同じでも毎回作り直しになり、無駄な再取得を招く。
 * 内容が同じなら同じ版、が正しい。
 *
 * WHY(Flutter の version.json を上書きするか): Flutter も同名のファイルを出すが、
 * 中身は `flutter_service_worker.js` スタブ専用。こちらは使わないスタブなので、
 * 診断用のアプリ情報だけ引き継いで入れ替える。
 */
function writeVersionFile() {
  const versionPath = join(buildDir, 'version.json');
  let appInfo;
  if (existsSync(versionPath)) {
    try {
      const previous = JSON.parse(readFileSync(versionPath, 'utf8'));
      appInfo = { app_name: previous.app_name, app_version: previous.app_version, build_number: previous.build_number };
    } catch (error) {
      appInfo = undefined;
    }
  }

  const hash = createHash('sha256');
  for (const name of VERSION_FINGERPRINT_FILES) {
    const path = join(buildDir, name);
    if (existsSync(path)) {
      hash.update(name);
      hash.update(readFileSync(path));
    }
  }
  const version = hash.digest('hex').slice(0, 16);
  const payload = { version, generated_at: new Date().toISOString(), ...(appInfo ?? {}) };
  writeFileSync(versionPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return version;
}

/** PWA として配れる状態か静的に確かめる。 */
function verifyPwa(version) {
  const problems = [];
  const workerPath = join(buildDir, 'service_worker.js');
  if (!existsSync(workerPath)) {
    problems.push('build/web/service_worker.js が無い（web/service_worker.js が配布物に入っていない）');
  } else if (!readFileSync(workerPath, 'utf8').includes("'use strict'")) {
    problems.push('build/web/service_worker.js が web/ のものと違う');
  }
  const versionPath = join(buildDir, 'version.json');
  if (!existsSync(versionPath) || !readFileSync(versionPath, 'utf8').includes(version)) {
    problems.push('build/web/version.json が書けていない');
  }
  const bootstrap = join(buildDir, 'flutter_bootstrap.js');
  if (existsSync(bootstrap)) {
    // 呼び出し側で `serviceWorkerSettings: { ... }` を渡していると、Flutter 側の
    // スタブ SW が登録され、こちらの SW を置き換えて開いているタブを強制リロードする。
    // 文字列の有無では判定できない（同梱の loader 本体にもテンプレートのコメントにも
    // 出てくる）ので、最後の `_flutter.loader.load(` 以降だけを見る。
    const text = readFileSync(bootstrap, 'utf8');
    const callIndex = text.lastIndexOf('_flutter.loader.load(');
    const call = callIndex >= 0 ? text.slice(callIndex) : '';
    if (!call.includes('serviceWorkerSettings: null')) {
      problems.push('flutter_bootstrap.js が Flutter 標準の Service Worker を止めていない');
    }
  }
  // 永続ストレージへの昇格は index.html にしかない。ここが抜けると、空き容量が
  // 逼迫した環境で保存データが黙って消える。
  const indexPath = join(buildDir, 'index.html');
  if (
    !existsSync(indexPath) ||
    !readFileSync(indexPath, 'utf8').includes('requestPersistentStorageAfterFirstSave')
  ) {
    problems.push('build/web/index.html に永続ストレージ昇格の仕掛けが無い');
  }

  const manifestPath = join(buildDir, 'manifest.json');  if (existsSync(manifestPath)) {
    try {
      const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
      if (manifest.lang !== 'ja') {
        problems.push(`manifest.json の lang が ja でない: ${manifest.lang}`);
      }
      if (!Array.isArray(manifest.icons) || manifest.icons.length < 2) {
        problems.push('manifest.json の icons が 192/512 を満たしていない');
      }
    } catch (error) {
      problems.push(`manifest.json を読めない: ${error.message}`);
    }
  } else {
    problems.push('build/web/manifest.json が無い');
  }
  return problems;
}

function main() {
  const options = parseArgs(process.argv.slice(2));

  if (!options.skipOcr) {
    process.stdout.write('== OCR 資産を作る ==\n');
    run(process.execPath, [join(here, 'ocr_vendor', 'build.mjs')]);
  } else {
    process.stdout.write('== OCR 資産は作り直さない（--skip-ocr）==\n');
  }

  process.stdout.write(`== flutter build web --release（base href: ${options.baseHref}）==\n`);
  run(FLUTTER, [
    'build',
    'web',
    '--release',
    `--base-href=${options.baseHref}`,
    // CanvasKit を自前配信する。付け忘れると gstatic から取りに行き、オフラインで動かない。
    '--no-web-resources-cdn',
  ]);

  const version = writeVersionFile();
  // verifyNoCdn は flutter_bootstrap.js の CanvasKit フラグを見るので、この順序で呼ぶ。
  const problems = [...verifyNoCdn(), ...verifyPwa(version)];
  const total = totalBytes(buildDir);
  process.stdout.write(`\nbuild/web 合計: ${total.toLocaleString()} バイト（${(total / 1024 / 1024).toFixed(1)} MiB）\n`);
  process.stdout.write(`Service Worker の版: ${version}\n`);
  if (problems.length > 0) {
    for (const problem of problems) {
      process.stdout.write(`エラー: ${problem}\n`);
    }
    process.exitCode = 1;
    return;
  }
  process.stdout.write('検証: CanvasKit は自前配信、OCR 資産は同梱済み、PWA の殻は揃っている。\n');
  process.stdout.write('注意: build/web 合計は複数レンダラ（canvaskit / skwasm / skwasm_heavy / wimp）を含む。\n');
  process.stdout.write('      初回に実際に取得されるのはこの合計ではない。reports/web-firstpaint-audit.md を参照。\n');
}

main();
