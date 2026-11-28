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
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..');
const buildDir = join(repoRoot, 'build', 'web');

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

  const problems = verifyNoCdn();
  const total = totalBytes(buildDir);
  process.stdout.write(`\nbuild/web 合計: ${total.toLocaleString()} バイト（${(total / 1024 / 1024).toFixed(1)} MiB）\n`);
  if (problems.length > 0) {
    for (const problem of problems) {
      process.stdout.write(`エラー: ${problem}\n`);
    }
    process.exitCode = 1;
    return;
  }
  process.stdout.write('検証: CanvasKit は自前配信、OCR 資産は同梱済み。\n');
  process.stdout.write('注意: build/web 合計は複数レンダラ（canvaskit / skwasm / skwasm_heavy / wimp）を含む。\n');
  process.stdout.write('      初回に実際に取得されるのはこの合計ではない。reports/web-firstpaint-audit.md を参照。\n');
}

main();
