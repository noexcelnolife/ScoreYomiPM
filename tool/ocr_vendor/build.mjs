// Web 版 OCR の資産を取得・バンドル・配置する唯一の手順。
//
// WHY スクリプトにするか: 配布物は合計 68,867,534 バイト（65.7 MiB、実測）あり、
// git に置かないと決めた（D-W16）。再現手段がスクリプト 1 本に集約されていれば、
// リポジトリを軽く保ったまま同じ成果物を何度でも作り直せる。手作業の複製は、
// どのファイルが必要だったかの知識を人の記憶に依存させるので行わない。
//
// 使い方: node tool/ocr_vendor/build.mjs
// 出力先: web/ocr_vendor/ （.gitignore 済み）
//   - 生成物 47,322,574 バイト: paddleocr.bundle.js / assets/ / licenses/ /
//     ort-wasm-simd-threaded.jsep.{mjs,wasm}
//   - 取得物 21,544,960 バイト: models/PP-OCRv5_mobile_{det,rec}.tar（無ければ取得、SHA-256 で固定）
//
// 配置を動かせない理由: パッケージは `new URL("./assets/worker-entry-<hash>.js",
// import.meta.url)` でワーカーを解決する。バンドル後もこの式は書き換わらないため、
// バンドルの隣に assets/ が無いと実行時に 404 になる。
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
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

/**
 * 複製する wasm は ONNX Runtime の **jsep 版 2 本**（糊の .mjs と本体の .wasm）。
 *
 * WHY jsep なのか: onnxruntime-web 1.24.3 の dist は webgpu 実行プロバイダを含む既定バンドルで、
 * 実行時に要求するのは `ort-wasm-simd-threaded.jsep.mjs`（糊）と
 * `ort-wasm-simd-threaded.jsep.wasm`（本体）の 2 本だけ。jsep でない
 * `ort-wasm-simd-threaded.wasm` は**一度も要求されない**（ブラウザ実測、
 * reports/web-ocr-browser-proof.md）。`ortOptions.backend` を `'wasm'` に固定しても
 * jsep が選ばれることも同じ実測で確認済み。
 *
 * 以前ここには「jsep 版は使わない（無駄）」と書いて jsep を配布物から外していた。
 * その結果、配信物には誰も要求しない wasm だけがあり、実際に要求される糊と本体が
 * 欠けていた（＝本番で初期化できない 404）。この判断は実測で否定されたので撤回する。
 * 糊（.mjs）を忘れると本体だけあっても読めないため、2 本を 1 組として扱う。
 */
const WASM_FILES = ['ort-wasm-simd-threaded.jsep.mjs', 'ort-wasm-simd-threaded.jsep.wasm'];

/**
 * 配るモデルは PP-OCRv5 mobile の det と rec の 2 本だけ。SHA-256 で内容を固定する。
 *
 * WHY ビルド時に取得するのか: tar 2 本で 21.5 MB あり、リポジトリに常設すると
 * 公開リポジトリの clone とフロントのビルドが恒久的に重くなる。かといって実行時に
 * CDN から取ると「外部送信 0 件」を満たせない。そこで**ビルド時に 1 度だけ取得**し、
 * `web/ocr_vendor/models/`（git 管理外）へ置く。取得物は配信物なので、
 * ビルドを回した人は必ず手元に持つことになる。
 *
 * WHY SHA-256 で固定するのか: 取得元は PaddlePaddle のモデル置き場で、URL は版ごとに
 * 固定されているが内容が将来入れ替わらない保証はない。ハッシュを固定しておけば、
 * 中身が変わったことにビルド時点で気づける（実行時に「精度が落ちた」と気づくより早い）。
 * ライセンスは Apache-2.0（`NOTICE.md` に出所とハッシュを書く）。
 */
const MODEL_SOURCES = [
  {
    name: 'PP-OCRv5_mobile_det.tar',
    url: 'https://paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0/PP-OCRv5_mobile_det_onnx_infer.tar',
    bytes: 4843520,
    sha256: '781056046c9ed77a15c94681605db6a0f62317c2e9cce6931c71da2478d4bc30',
  },
  {
    name: 'PP-OCRv5_mobile_rec.tar',
    url: 'https://paddle-model-ecology.bj.bcebos.com/paddlex/official_inference_model/paddle3.0.0/PP-OCRv5_mobile_rec_onnx_infer.tar',
    bytes: 16701440,
    sha256: 'f7e792bc836f36e7ef895ad47c426d75b0b75b1650caa6d63fe9418441ffba8c',
  },
];

/** 取得したモデルの置き場。生成物ではないので cleanGeneratedArtifacts() は触らない。 */
const modelsDir = join(outDir, 'models');

/**
 * 削除対象は「このスクリプトが作る生成物」だけ。outDir ごと消してはならない。
 *
 * WHY: web/ocr_vendor/models/ は外部から取得した**配布物**であって、このスクリプトが
 * esbuild で作る生成物ではない。outDir を丸ごと rmSync すると毎回モデルまで消え、
 * ローカルで OCR を試すたびに 21.5 MB を再取得することになる（実際に OCR-B1/B2 の検証で 3 回踏んだ）。
 * 「models/ を残す」と名指しで除外するのではなく、「消すもの＝生成物」を明示する。
 * 逆（残す側を列挙）にすると、将来 web/ocr_vendor/ に別の取得物が増えたとき同じ事故が起きる。
 */
const GENERATED_ENTRIES = ['paddleocr.bundle.js', 'assets', 'licenses'];

/**
 * wasm は名前が変わっても（simd / jsep / jspi / asyncify）古いものを残さない。
 * 糊の `.mjs` も対象に入れる。WHY: 本体（.wasm）だけ消して糊が残ると、
 * 版や変種の違う糊と本体が混ざった配信物になり、実行時に原因の分かりにくい失敗になる。
 */
const GENERATED_WASM_PATTERN = /^ort-wasm-.*\.(wasm|mjs)$/;

function isGeneratedEntry(name) {
  return GENERATED_ENTRIES.includes(name) || GENERATED_WASM_PATTERN.test(name);
}

/** 生成物だけを消す。outDir 自体と取得物（models/）は残す。 */
function cleanGeneratedArtifacts() {
  if (!existsSync(outDir)) {
    return;
  }
  for (const entry of readdirSync(outDir, { withFileTypes: true })) {
    if (!isGeneratedEntry(entry.name)) {
      continue;
    }
    rmSync(join(outDir, entry.name), { recursive: true, force: true });
  }
}

/**
 * ワーカーは ONNX Runtime Web を内包済みで、版は「ONNX Runtime Web v1.24.3」と書かれている。
 * 糊（.mjs）と本体（.wasm）は版が一致しないと実行時に落ちるため、package.json で 1.24.3 に固定する。
 * ここでは固定が外れていないかを実際に突き合わせて落とす（配る前に気づくため）。
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

async function bundle() {
  cleanGeneratedArtifacts();
  mkdirSync(join(outDir, 'assets'), { recursive: true });
  // WHY 名前空間を globalThis へ公開するのか: Dart からは動的に読み込んだ ES モジュールの
  // 名前空間を直接受け取れない（<script type="module"> の評価結果は外に出てこない）。
  // `export *` のままだと、モジュールを読み込めても中身を掴む手段が無い。
  // そこでバンドル自身が `globalThis.ScoreYomiOcr` に生やし、Dart 側は
  // 読み込み完了後にそのプロパティを読む。
  writeFileSync(
    entryPath,
    "import * as paddle from '@paddleocr/paddleocr-js';\nglobalThis.ScoreYomiOcr = paddle;\n",
    'utf8',
  );
  log('バンドル: esbuild 実行中...');
  try {
    // esbuild は静的 import にしてはならない。
    // WHY: ESM の静的 import は「モジュール本体のコードが 1 行も走る前」に解決される。
    // 依存を入れる ensureDependencies() は main() の中で走るため、node_modules がまだ無い
    // 状態（GitHub Actions の初回実行）では依存導入より解決が先に走って
    // `ERR_MODULE_NOT_FOUND: Cannot find package 'esbuild'` で落ちる。
    // 依存を入れ終わった後まで解決を遅らせるため、ここで動的 import する。
    const { buildSync } = await import('esbuild');
    // CLI（node_modules/esbuild/bin/esbuild）を node で起動してはならない。
    // WHY: このパスは Windows では JS のシムだが、Linux/macOS ではプラットフォーム用の
    // 実行バイナリ本体（ELF / Mach-O）になる。node が JS として読もうとして
    // `SyntaxError: Invalid or unexpected token` で落ちる（GitHub Actions で実際に発生）。
    // JS API ならプラットフォーム別バイナリの解決を esbuild 自身が行うため、どの OS でも同じ。
    buildSync({
      entryPoints: [entryPath],
      bundle: true,
      format: 'esm',
      minify: true,
      target: 'es2020',
      // opencv-js は Emscripten の Node 用シェルで require("fs")/require("path") を含む。
      // package.json に browser フィールドが無いため解決に失敗して停止する。
      // 当該分岐は ENVIRONMENT_IS_NODE のときだけ通るので、ブラウザでは到達しない。
      external: ['fs', 'path'],
      outfile: bundlePath,
      logLevel: 'info',
    });
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
  const dist = join(here, 'node_modules', 'onnxruntime-web', 'dist');
  for (const name of WASM_FILES) {
    const source = join(dist, name);
    if (!existsSync(source)) {
      failures.push(`wasm が見つからない: ${source}`);
      continue;
    }
    copyFileSync(source, join(outDir, name));
  }
}

/** ファイルの SHA-256 を小文字の hex で返す。 */
function sha256Of(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

/** 取得済みのモデルが固定したハッシュと一致するか確かめる。 */
function verifyModel(path, model) {
  const actual = sha256Of(path);
  if (actual !== model.sha256) {
    failures.push(
      `モデルの内容が固定値と違う: ${model.name}（実測 ${actual} / 期待 ${model.sha256}）。` +
        ' 取得元が差し替わった可能性がある。中身を確認するまで配らないこと',
    );
    return false;
  }
  return true;
}

/** 1 本だけ取得する。一時ファイルへ書いてから rename するので、途中で落ちても壊れた tar は残らない。 */
async function downloadModel(model) {
  const target = join(modelsDir, model.name);
  const temporary = `${target}.download`;
  log(`取得: ${model.name} ← ${model.url}`);
  let response;
  try {
    response = await fetch(model.url);
  } catch (error) {
    failures.push(`モデルを取得できない: ${model.name}（${error.message}）`);
    return;
  }
  if (!response.ok) {
    failures.push(`モデルの取得に失敗した: ${model.name} HTTP ${response.status}`);
    return;
  }
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length !== model.bytes) {
    failures.push(`モデルのサイズが固定値と違う: ${model.name}（実測 ${bytes.length} / 期待 ${model.bytes}）`);
    return;
  }
  writeFileSync(temporary, bytes);
  if (!verifyModel(temporary, model)) {
    rmSync(temporary, { force: true });
    return;
  }
  renameSync(temporary, target);
  log(`取得完了: ${model.name}（${mib(model.bytes)} MiB）`);
}

/**
 * 配るモデルを揃える。無ければ取得し、あればハッシュだけ確かめる。
 * 既にあるものを黙って上書きしない（取得元が差し替わったときに気づけなくなるため）。
 */
async function ensureModels() {
  mkdirSync(modelsDir, { recursive: true });
  for (const model of MODEL_SOURCES) {
    const target = join(modelsDir, model.name);
    if (existsSync(target)) {
      if (verifyModel(target, model)) {
        log(`モデル: 取得済み（ハッシュ一致）${model.name}`);
      }
      continue;
    }
    await downloadModel(model);
  }
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

/** ディレクトリ配下のファイルを [相対名, バイト数] で平らにする。 */
function listFiles(dir, prefix = '') {
  const files = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...listFiles(full, `${prefix}${entry.name}/`));
      continue;
    }
    files.push([`${prefix}${entry.name}`, sizeOf(full)]);
  }
  return files;
}

/** 大きい順に並べて出力し、合計を返す。 */
function printFiles(files) {
  let total = 0;
  for (const [name, bytes] of files.sort((a, b) => b[1] - a[1])) {
    total += bytes;
    log(`  ${String(bytes).padStart(12)}  ${name}`);
  }
  log(`  合計 ${total} バイト（${mib(total)} MiB）`);
  return total;
}

function report() {
  // 生成物と取得物（models/）は出所が違うので分けて出す。
  // 混ぜると「esbuild が何を出したか」と「外から何を取ったか」が区別できなくなる。
  log('配布物（生成物）:');
  const generated = [];
  for (const entry of readdirSync(outDir, { withFileTypes: true })) {
    if (!isGeneratedEntry(entry.name)) {
      continue;
    }
    if (entry.isDirectory()) {
      generated.push(...listFiles(join(outDir, entry.name), `${entry.name}/`));
      continue;
    }
    generated.push([entry.name, sizeOf(join(outDir, entry.name))]);
  }
  const generatedTotal = printFiles(generated);
  log('この合計は初回描画には含まれない（OCR 実行時に動的 import する）。');

  log('配布物（models/・ビルド時に取得）:');
  const models = existsSync(modelsDir) ? listFiles(modelsDir, 'models/') : [];
  const modelsTotal = printFiles(models);

  log(`配布物 合計 ${generatedTotal + modelsTotal} バイト（${mib(generatedTotal + modelsTotal)} MiB）`);
}

async function main() {
  ensureDependencies();
  assertOrtVersionMatches();
  await ensureModels();
  await bundle();
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

await main();
