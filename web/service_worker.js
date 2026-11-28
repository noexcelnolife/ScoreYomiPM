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
// 方針（reports/web-pwa-plan.md）:
//   1. install 時に保存するのは「殻」だけ（index.html など 100KB 未満）
//   2. 大きな資産は初回アクセス時に遅延保存する
//   3. 版が変わったら殻だけ差し替える。開いているタブは勝手にリロードしない

'use strict';

const VERSION_PATH = 'version.json';
const SHELL_CACHE_PREFIX = 'scoreyomi-shell-';

// WHY(資産キャッシュに版を付けないか): OCR 資産 68.9MB と CanvasKit 38MB を
// 版のたびに捨てると、更新のたびに 100MB を取り直すことになる。内容が変わった
// ファイルだけを stale-while-revalidate で置き換える。
const ASSET_CACHE = 'scoreyomi-assets';

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

/** version.json の版。取れなければ null（キャッシュ名には 'unknown' を使う）。 */
async function readVersion() {
  try {
    const response = await fetch(scopeUrl(VERSION_PATH), { cache: 'no-store' });
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

async function dropStaleShellCaches(keepName) {
  const names = await caches.keys();
  await Promise.all(
    names
      .filter((name) => name.startsWith(SHELL_CACHE_PREFIX) && name !== keepName)
      .map((name) => caches.delete(name)),
  );
}

/**
 * 版が変わっていたら殻だけ差し替える。
 *
 * WHY(開いているタブに通知しないか): 版の切り替えは次回起動時に効けばよい。
 * 実行中のタブをリロードすると入力途中のフォームが消える。
 */
async function syncVersion() {
  const version = await readVersion();
  // 起動直後は currentVersion が null なので、まずキャッシュ名から今の版を復元する。
  // そこで復元せずに比べると、毎回「版が変わった」と誤認して殻を取り直してしまう。
  if (version === null || version === (await resolveCurrentVersion())) {
    return;
  }
  try {
    await cacheShell(version);
  } catch (error) {
    // 殻の取り直しに失敗したら、今の版のまま動かす。
    return;
  }
  currentVersion = version;
  await dropStaleShellCaches(SHELL_CACHE_PREFIX + version);
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

// 資産をキャッシュから返してよい期間。過ぎたら裏で取り直す（表示は変えない）。
//
// WHY(毎回取り直さないか): stale-while-revalidate を素朴に実装すると、キャッシュに
// 当たった場合でも毎回 fetch を投げる。するとこのアプリでは 1 回の起動で
// CanvasKit・フォント・資産を全部「確認」しに行くことになり、
// 「2 回目以降は取りに行かない」が成立しない。変更は殻の版で検知し、
// 資産は期限付きで静かに更新する。
const ASSET_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

/** 取得したバイト列を保存する。保存できなくても取得は成功させる。 */
async function fetchAndStore(cache, request) {
  const response = await fetch(request);
  if (response.ok) {
    await writeToCache(cache, request, response.clone());
  }
  return response;
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

async function staleWhileRevalidate(event, request) {
  const cache = await caches.open(ASSET_CACHE);
  const cached = await cache.match(request);
  if (cached) {
    if (isStale(cached)) {
      // 表にはキャッシュを返し、裏で更新する。結果は次回以降に効く。
      event.waitUntil(fetchAndStore(cache, request).catch(() => undefined));
    }
    return cached;
  }
  return fetchAndStore(cache, request);
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
      if (currentVersion === null) {
        currentVersion = (await readVersion()) ?? 'unknown';
      }
      await dropStaleShellCaches(SHELL_CACHE_PREFIX + currentVersion);
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
    event.respondWith(networkFirst('index.html', request));
    event.waitUntil(syncVersion());
    return;
  }
  if (NETWORK_FIRST_FILES.has(path)) {
    event.respondWith(networkFirst(path, request));
    return;
  }
  event.respondWith(staleWhileRevalidate(event, request));
});
