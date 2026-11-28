// Web 版 OCR の資産を取得・バンドル・配置する唯一の手順。
//
// WHY スクリプトにするか: 生成物は合計 35.4 MiB（実測、reports/web-ocr-bundle-feasibility.md）
// あり、git に置かないと決めた（D-W16）。再現手段がスクリプト 1 本に集約されていれば、
// リポジトリを軽く保ったまま同じ成果物を何度でも作り直せる。手作業の複製は、
// どのファイルが必要だったかの知識を人の記憶に依存させるので行わない。
//
// 使い方: node tool/ocr_vendor/build.mjs
// 出力先: web/ocr_vendor/ （.gitignore 済み）
//
// 配置を動かせない理由: パッケージは `new URL("./assets/worker-entry-<hash>.js",
// import.meta.url)` でワーカーを解決する。バンドル後もこの式は書き換わらないため、
// バンドルの隣に assets/ が無いと実行時に 404 になる。
import { execFileSync } from 'node:child_process';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..', '..');
const outDir = join(repoRoot, 'web', 'ocr_vendor');
const bundlePath = join(outDir, 'paddleocr.bundle.js');
const entryPath = join(here, '.entry.mjs');

/** 複製する wasm は 1 本だけ。jsep / jspi / asyncify 版は使わない（計 76 MiB の無駄）。 */
const WASM_NAME = 'ort-wasm-simd-threaded.wasm';

/**
 * ワーカーは ONNX Runtime Web を内包済みで、版は「ONNX Runtime Web v1.24.3」と書かれている。
 * wasm は JS 側の糊と版が一致しないと実行時に落ちるため、package.json で 1.24.3 に固定する。
 * ここでは固定が外れていないかを実際に突き合わせて落とす（37 MiB を無駄に配らないため）。
 */
const ORT_VERSION_IN_WORKER = /ONNX Runtime Web v(\d+\.\d+\.\d+)/;

/** ライセンス表記のために同梱する LICENSE の取得元。 */
const LICENSE_SOURCES = [
  ['@paddleocr/paddleocr-js', 'paddleocr-js'],
  ['@techstark/opencv-js', 'opencv-js'],
  ['onnxruntime-web', 'onnxruntime-web'],
  ['js-yaml', 'js-yaml'],
  ['clipper-lib', 'clipper-lib'],
];

const failures = [];

function log(message) {
  process.stdout.write(`${message}\n`);
}

function sizeOf(path) {
  return statSync(path).size;
}

function mib(bytes) {
  return (bytes / 1024 / 1024).toFixed(1);
}

/** npm は Windows で .cmd なので shell 経由でないと起動できない。 */
function runNpm(args) {
  execFileSync(process.platform === 'win32' ? 'npm.cmd' : 'npm', args, {
    cwd: here,
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });
}

function ensureDependencies() {
  if (existsSync(join(here, 'node_modules'))) {
    log('依存: node_modules があるため npm ci を省略');
    return;
  }
  // lockfile があるときだけ ci（再現性優先）。無ければ install で作る。
  const hasLock = existsSync(join(here, 'package-lock.json'));
  log(`依存: ${hasLock ? 'npm ci' : 'npm install'} を実行`);
  runNpm([hasLock ? 'ci' : 'install', '--no-audit', '--no-fund']);
}

function bundle() {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(join(outDir, 'assets'), { recursive: true });
  writeFileSync(entryPath, "export * from '@paddleocr/paddleocr-js';\n", 'utf8');
  log('バンドル: esbuild 実行中...');
  try {
    execFileSync(
      process.execPath,
      [
        join(here, 'node_modules', 'esbuild', 'bin', 'esbuild'),
        entryPath,
        '--bundle',
        '--format=esm',
        '--minify',
        '--target=es2020',
        // opencv-js は Emscripten の Node 用シェルで require("fs")/require("path") を含む。
        // package.json に browser フィールドが無いため解決に失敗して停止する。
        // 当該分岐は ENVIRONMENT_IS_NODE のときだけ通るので、ブラウザでは到達しない。
        '--external:fs',
        '--external:path',
        `--outfile=${bundlePath}`,
      ],
      { cwd: here, stdio: 'inherit' },
    );
  } finally {
    rmSync(entryPath, { force: true });
  }
}

function copyWorkerAssets() {
  const source = join(here, 'node_modules', '@paddleocr', 'paddleocr-js', 'dist', 'assets');
  if (!existsSync(source)) {
    failures.push(`ワーカーが見つからない: ${source}`);
    return;
  }
  // .map は 12 MiB あり、ブラウザは取得しない。配る意味が無いので複製しない。
  const target = join(outDir, 'assets');
  for (const name of readdirSync(source)) {
    if (name.endsWith('.map')) {
      continue;
    }
    copyFileSync(join(source, name), join(target, name));
  }
}

function copyWasm() {
  const source = join(here, 'node_modules', 'onnxruntime-web', 'dist', WASM_NAME);
  if (!existsSync(source)) {
    failures.push(`wasm が見つからない: ${source}`);
    return;
  }
  copyFileSync(source, join(outDir, WASM_NAME));
}

/** ワーカー内蔵の ORT と、複製する wasm の版を突き合わせる。 */
function assertOrtVersionMatches() {
  const assets = join(here, 'node_modules', '@paddleocr', 'paddleocr-js', 'dist', 'assets');
  const worker = existsSync(assets)
    ? readdirSync(assets).find((name) => /^worker-entry-.*\.js$/.test(name))
    : undefined;
  if (worker === undefined) {
    failures.push('ワーカーのファイル名を特定できない（版の突き合わせ不能）');
    return;
  }
  const match = readFileSync(join(assets, worker), 'utf8').match(ORT_VERSION_IN_WORKER);
  if (match === null) {
    failures.push(`ワーカーから ONNX Runtime の版を読めない: ${worker}`);
    return;
  }
  const embedded = match[1];
  const installed = JSON.parse(
    readFileSync(join(here, 'node_modules', 'onnxruntime-web', 'package.json'), 'utf8'),
  ).version;
  if (embedded !== installed) {
    failures.push(
      `ONNX Runtime の版が食い違う: ワーカー内蔵 ${embedded} / node_modules ${installed}。` +
        ' package.json の onnxruntime-web を固定し直すこと',
    );
    return;
  }
  log(`版の一致: ONNX Runtime Web ${embedded}（ワーカー内蔵 = 複製する wasm）`);
}

function copyLicenses() {
  const target = join(outDir, 'licenses');
  mkdirSync(target, { recursive: true });
  // 1) パッケージが同梱している LICENSE（opencv-js と js-yaml は同梱している）。
  for (const [packageName, alias] of LICENSE_SOURCES) {
    const base = join(here, 'node_modules', ...packageName.split('/'));
    const license = readdirSync(base).find((name) => /^licen[cs]e/i.test(name));
    if (license === undefined) {
      // paddleocr-js / onnxruntime-web / clipper-lib は npm 版に LICENSE を同梱していない。
      log(`  LICENSE 同梱なし（licenses/ の写しで補う）: ${packageName}`);
      continue;
    }
    copyFileSync(join(base, license), join(target, `${alias}.txt`));
  }
  // 2) 同梱されていないパッケージ用の正規ライセンス全文。由来を追えるよう git で管理する。
  const local = join(here, 'licenses');
  if (existsSync(local)) {
    for (const name of readdirSync(local)) {
      copyFileSync(join(local, name), join(target, name));
    }
  }
}

function report() {
  const files = [];
  const walk = (dir, prefix) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full, `${prefix}${entry.name}/`);
        continue;
      }
      files.push([`${prefix}${entry.name}`, sizeOf(full)]);
    }
  };
  walk(outDir, '');

  let total = 0;
  for (const [name, bytes] of files.sort((a, b) => b[1] - a[1])) {
    total += bytes;
    log(`  ${String(bytes).padStart(12)}  ${name}`);
  }
  log(`  合計 ${total} バイト（${mib(total)} MiB）`);
  log('この合計は初回描画には含まれない（OCR 実行時に動的 import する）。');
}

function main() {
  ensureDependencies();
  assertOrtVersionMatches();
  bundle();
  copyWorkerAssets();
  copyWasm();
  copyLicenses();
  log(`出力: ${outDir}`);
  report();

  if (failures.length > 0) {
    for (const failure of failures) {
      log(`エラー: ${failure}`);
    }
    process.exitCode = 1;
    return;
  }
  log('完了。`flutter build web` の前に必ずこのスクリプトを実行すること。');
}

main();
