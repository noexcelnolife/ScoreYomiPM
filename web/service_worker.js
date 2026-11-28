// スコアヨミPM の Service Worker。
//
// WHY(Flutter の生成物を使わないか): `flutter build web` が出す
// flutter_service_worker.js は「自分を unregister して開いている全タブを
// 強制リロードする」スタブで、入力途中のフォームを壊す。しかもキャッシュ対象を
// 選べない。本アプリは CanvasKit 38MB と OCR 資産 68.9MB をインストール時に
// 落とさないと決めているので、対象を自分で選ぶ必要がある。
// そのため `web/flutter_bootstrap.js` で `serviceWorkerSettings: null` を渡し、
// Flutter 側の登録は止めてある。
//
// キャッシュは 3 種類。
//   scoreyomi-shell-<版>   起動に要る殻（index.html / manifest.json / icons など）
//   scoreyomi-build-<版>   ビルドが生成した資産（main.dart.js / canvaskit / AssetManifest …）
//   scoreyomi-static      版に依存しない重い資産（ocr_vendor/** / assets/**/fonts/**）
//
// WHY(ビルド産物を版付きにするか): 版を変えたのに `main.dart.js` を古いまま返すと、
// 「殻は新しいのにアプリは古い」状態になり更新が届かない。実際、版を持たない
// 共通キャッシュ + stale-while-revalidate では、`Date` が 7 日以内だと
// 再取得されず、`window.__DEPLOY_B` のような新しいアプリの印が出なかった。
// 版付きにすれば、版が変わった読み込みで必ず取り直し、同じ版なら 1 バイトも動かさない。
//
// WHY(OCR 資産とフォントを版から外すか): 68.9MB + 6.5MB を版のたびに捨てると、
// 更新のたびに 75MB を取り直すことになる。内容が変わったときだけ期限付きで
// 静かに更新する（ASSET_MAX_AGE_MS）。

'use strict';

const VERSION_PATH = 'version.json';
const SHELL_CACHE_PREFIX = 'scoreyomi-shell-';
const BUILD_CACHE_PREFIX = 'scoreyomi-build-';
const STATIC_CACHE = 'scoreyomi-static';

// 版に依存しない資産。ここに入るものは版が変わっても捨てない。
const STATIC_PREFIXES = ['ocr_vendor/', 'assets/assets/fonts/', 'assets/fonts/'];

// 起動に要る殻。ここだけは install 時に取りに行く。
const SHELL_FILES = [
  'index.html',
  'manifest.json',
  VERSION_PATH,
  'flutter_bootstrap.js',
  'flutter.js',
  'favicon.png',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'icons/Icon-maskable-192.png',
  'icons/Icon-maskable-512.png',
];

// 殻のうち、取れなかったら install を失敗させるもの。欠けた状態でキャッシュすると
// オフライン起動が「真っ白」で失敗するより分かりにくい。
const REQUIRED_SHELL_FILES = new Set(['index.html', 'manifest.json', VERSION_PATH, 'flutter_bootstrap.js']);

// この 3 つは小さく、版の切り替えを早く反映したいので常に取りに行く。
const NETWORK_FIRST_FILES = new Set(['index.html', 'manifest.json', 'flutter_bootstrap.js']);

// 版に依存しない資産を「裏で取り直す」までの猶予。
const ASSET_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

// 版の確認が固まって起動を待たせ続けないための上限。
const VERSION_TIMEOUT_MS = 5000;

let currentVersion = null;

/** 登録スコープ（GitHub Pages では /ScoreYomiPM/）基準の絶対 URL。 */
function scopeUrl(path) {
  return new URL(path, self.registration.scope).href;
}

/** リクエスト URL をスコープからの相対パスにする。範囲外なら null。 */
function relativePath(url) {
  const scopePath = new URL(self.registration.scope).pathname;
  if (!url.pathname.startsWith(scopePath)) {
    return null;
  }
  return url.pathname.slice(scopePath.length);
}

function isStaticPath(path) {
  return STATIC_PREFIXES.some((prefix) => path.startsWith(prefix));
}

/** version.json の版。取れなければ null（オフライン時など）。 */
async function readVersion() {
  try {
    const options = { cache: 'no-store' };
    // 古いブラウザには AbortSignal.timeout が無い。無ければ待ち続ける（従来どおり）。
    if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
      options.signal = AbortSignal.timeout(VERSION_TIMEOUT_MS);
    }
    const response = await fetch(scopeUrl(VERSION_PATH), options);
    if (!response.ok) {
      return null;
    }
    const data = await response.json();
    return typeof data.version === 'string' && data.version.length > 0 ? data.version : null;
  } catch (error) {
    return null;
  }
}

async function openShellCache(version) {
  return caches.open(SHELL_CACHE_PREFIX + version);
}

async function cacheShell(version) {
  const cache = await openShellCache(version);
  for (const path of SHELL_FILES) {
    try {
      await cache.add(new Request(scopeUrl(path), { cache: 'reload' }));
    } catch (error) {
      if (REQUIRED_SHELL_FILES.has(path)) {
        throw error;
      }
      // flutter.js など、ビルドによっては存在しないファイルは無視する。
    }
  }
  return cache;
}

/** [prefix] で始まるキャッシュを、[keepName] 以外すべて消す。 */
async function dropCachesExcept(prefix, keepName) {
  const names = await caches.keys();
  await Promise.all(
    names
      .filter((name) => name.startsWith(prefix) && name !== keepName)
      .map((name) => caches.delete(name)),
  );
}

/**
 * 版が変わっていたら、殻とビルド産物を新しい版に切り替える。
 *
 * WHY(開いているタブに通知しないか): 版の切り替えは次回起動時に効けばよい。
 * 実行中のタブをリロードすると入力途中のフォームが消える。
 *
 * WHY(戻り値を版にするか): 呼び出し側（ナビゲーション）が、この処理の完了を
 * 待ってから index.html を返す必要がある。待たずに返すと、ページが投げる
 * `main.dart.js` の要求が古い版のキャッシュに当たり、更新が届かない。
 */
async function syncVersion() {
  const current = await resolveCurrentVersion();
  const version = await readVersion();
  if (version === null || version === current) {
    return current;
  }
  try {
    await cacheShell(version);
  } catch (error) {
    // 殻の取り直しに失敗したら、今の版のまま動かす。
    return current;
  }
  currentVersion = version;
  // 旧版の殻とビルド産物を消す。版に依存しない資産（OCR・フォント）は残す。
  await dropCachesExcept(SHELL_CACHE_PREFIX, SHELL_CACHE_PREFIX + version);
  await dropCachesExcept(BUILD_CACHE_PREFIX, BUILD_CACHE_PREFIX + version);
  return version;
}

/** 保存は「できれば得」。失敗しても取得自体は成功させる。 */
async function writeToCache(cache, key, response) {
  try {
    await cache.put(key, response);
  } catch (error) {
    // WHY(握りつぶすか): OCR の wasm（25MB）などを保存しようとして
    // QuotaExceededError が出ると、未処理のまま通信全体が失敗して OCR が
    // 動かなくなる。保存できなくても通常取得として続行させたい。
    console.warn('キャッシュに保存できませんでした:', key, error);
  }
}

/** 存在する殻キャッシュの名前（新しい順は保証しない）。 */
async function shellCacheNames() {
  return (await caches.keys()).filter((name) => name.startsWith(SHELL_CACHE_PREFIX));
}

/**
 * 今の版を決める。
 *
 * WHY(キャッシュ名から復元するか): `currentVersion` は Service Worker の
 * 起動ごとに null に戻る。アイドルで停止した後の再起動では install も activate も
 * 走らないため、そこでネットワークに聞きに行くとオフライン時に版が分からず、
 * `scoreyomi-shell-unknown` を探して空振りする（＝オフライン起動が真っ白になる）。
 * 殻キャッシュは版ごとに 1 つしか残さないので、その名前がそのまま今の版になる。
 */
async function resolveCurrentVersion() {
  if (currentVersion !== null) {
    return currentVersion;
  }
  const names = await shellCacheNames();
  if (names.length > 0) {
    currentVersion = names[0].slice(SHELL_CACHE_PREFIX.length);
    return currentVersion;
  }
  currentVersion = (await readVersion()) ?? 'unknown';
  return currentVersion;
}

/** 殻を読む。今の版のキャッシュを先に、無ければ残っている殻キャッシュ全部を見る。 */
async function readShell(cacheKey) {
  if (currentVersion !== null) {
    const cached = await (await openShellCache(currentVersion)).match(cacheKey);
    if (cached) {
      return cached;
    }
  }
  for (const name of await shellCacheNames()) {
    const cached = await (await caches.open(name)).match(cacheKey);
    if (cached) {
      return cached;
    }
  }
  return null;
}

async function networkFirst(path, request) {
  const version = await resolveCurrentVersion();
  const cache = await openShellCache(version);
  const cacheKey = scopeUrl(path);
  try {
    const response = await fetch(request);
    if (response.ok) {
      await writeToCache(cache, cacheKey, response.clone());
    }
    return response;
  } catch (error) {
    const cached = await readShell(cacheKey);
    if (cached) {
      return cached;
    }
    throw error;
  }
}

/** 取得したバイト列を保存する。保存できなくても取得は成功させる。 */
async function fetchAndStore(cache, request) {
  const response = await fetch(request);
  if (response.ok) {
    await writeToCache(cache, request, response.clone());
  }
  return response;
}

/**
 * ビルド産物を返す（版付きキャッシュ、キャッシュ優先）。
 *
 * WHY(cache を reload にするか): 版が変わった直後の 1 回だけ走る処理なので、
 * ブラウザの HTTP キャッシュ（GitHub Pages は max-age=600）に古い実体を
 * 返されると「新しい版なのに古いコード」になる。必ず実体を取りに行く。
 */
/**
 * SW が返す応答はブラウザの HTTP キャッシュに残さない。
 *
 * WHY(必要なのか): 版を変えた再読み込みで `main.dart.js` が SW に届かなかった。
 * ブラウザが自前のキャッシュから直接返してしまい、fetch イベントが発火しないため、
 * SW 側をどう直しても新しいビルドが動かない（実測: サーバへの要求 0 件、
 * ページの目印も古いまま、`deliveryType=cache-storage` / `workerStart=0`）。
 * 版の判定を SW のキャッシュだけに一本化するため、SW が返す応答は
 * キャッシュさせない。これで次の読み込みは必ず SW を通る。
 */
function noStore(response) {
  if (!response || response.type === 'opaque') {
    return response;
  }
  const headers = new Headers(response.headers);
  headers.set('cache-control', 'no-store');
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

async function buildFirst(request) {
  const version = await resolveCurrentVersion();
  const cache = await caches.open(BUILD_CACHE_PREFIX + version);
  const cached = await cache.match(request);
  if (cached) {
    return cached;
  }
  return fetchAndStore(cache, new Request(request, { cache: 'reload' }));
}

/** 版に依存しない資産を返す。期限を過ぎたものだけ裏で取り直す。 */
async function staticFirst(event, request) {
  const cache = await caches.open(STATIC_CACHE);
  const cached = await cache.match(request);
  if (!cached) {
    return fetchAndStore(cache, request);
  }
  if (isStale(cached)) {
    // 表にはキャッシュを返し、裏で更新する。結果は次回以降に効く。
    event.waitUntil(fetchAndStore(cache, request).catch(() => undefined));
  }
  return cached;
}

/** キャッシュ済みの応答が古いかどうか。日付が無いものは古くない扱い。 */
function isStale(response) {
  const servedAt = response.headers.get('date');
  if (servedAt === null) {
    return false;
  }
  const age = Date.now() - Date.parse(servedAt);
  return Number.isFinite(age) && age > ASSET_MAX_AGE_MS;
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    (async () => {
      const version = (await readVersion()) ?? 'unknown';
      currentVersion = version;
      await cacheShell(version);
      // WHY(skipWaiting か): 待たせると新しい SW が有効になるのが次々回の
      // 起動になり、更新が届かない。待たせずに有効化し、リロードはしない。
      await self.skipWaiting();
    })(),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const version = await resolveCurrentVersion();
      await dropCachesExcept(SHELL_CACHE_PREFIX, SHELL_CACHE_PREFIX + version);
      await dropCachesExcept(BUILD_CACHE_PREFIX, BUILD_CACHE_PREFIX + version);
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') {
    return;
  }
  const url = new URL(request.url);
  // 他オリジン（fonts.gstatic.com など）はブラウザに任せる。中継しても
  // opaque レスポンスの扱いが増えるだけで得がない。
  if (url.origin !== self.location.origin) {
    return;
  }
  // 版は常に実物を見る。キャッシュから返すと更新を検知できなくなる。
  if (url.pathname.endsWith('/' + VERSION_PATH)) {
    return;
  }
  const path = relativePath(url);
  if (path === null) {
    return;
  }
  if (request.mode === 'navigate' || path.length === 0) {
    // WHY(版の確定を待つか): ここを待たずに index.html を返すと、ページが投げる
    // `main.dart.js` の要求が古い版のキャッシュに当たり、更新が届かない。
    event.respondWith(
      (async () => {
        await syncVersion();
        return noStore(await networkFirst('index.html', request));
      })(),
    );
    return;
  }
  if (NETWORK_FIRST_FILES.has(path)) {
    event.respondWith(networkFirst(path, request).then(noStore));
    return;
  }
  if (isStaticPath(path)) {
    event.respondWith(staticFirst(event, request).then(noStore));
    return;
  }
  event.respondWith(buildFirst(request).then(noStore));
});
