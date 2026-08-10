import { spawn } from 'node:child_process';
import { access, readFile } from 'node:fs/promises';
import { createServer as createHttpServer } from 'node:http';
import { createServer as createNetServer } from 'node:net';
import path from 'node:path';
import process from 'node:process';

const repositoryRoot = path.resolve(import.meta.dirname, '..', '..');
const buildRoot = path.join(repositoryRoot, 'build', 'web');
const chromeDriverBinary =
  process.env.CHROMEDRIVER_BINARY ??
  (process.platform === 'win32' ? 'chromedriver.exe' : 'chromedriver');
const viewports = Object.freeze([
  { height: 700, name: 'narrow phone', width: 320 },
  { height: 844, name: 'standard phone', width: 390 },
  { height: 1024, name: 'tablet', width: 768 },
  { height: 900, name: 'desktop', width: 1280 }
]);
const mimeTypes = new Map([
  ['.css', 'text/css; charset=utf-8'],
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.png', 'image/png'],
  ['.svg', 'image/svg+xml'],
  ['.webp', 'image/webp'],
  ['.woff2', 'font/woff2']
]);

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function reserveLoopbackPort() {
  return new Promise((resolve, reject) => {
    const server = createNetServer();
    server.unref();
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      const port =
        typeof address === 'object' && address !== null
          ? address.port
          : undefined;
      server.close((error) => {
        if (error) reject(error);
        else if (port === undefined) {
          reject(new Error('Failed to allocate a loopback port.'));
        } else resolve(port);
      });
    });
  });
}

async function terminateChild(child) {
  if (!child || child.exitCode !== null) return;
  if (!child.killed) child.kill('SIGTERM');
  await Promise.race([
    new Promise((resolve) => child.once('exit', resolve)),
    sleep(3_000)
  ]);
  if (child.exitCode === null) child.kill('SIGKILL');
}

async function waitForChromeDriver(child, port, diagnostics) {
  const deadline = Date.now() + 15_000;
  const statusUrl = `http://127.0.0.1:${port}/status`;
  let spawnError;
  const recordSpawnError = (error) => {
    spawnError = error;
  };
  child.once('error', recordSpawnError);
  try {
    while (Date.now() < deadline) {
      if (spawnError) throw spawnError;
      if (child.exitCode !== null) {
        throw new Error(
          `ChromeDriver exited before becoming ready.\n${diagnostics()}`
        );
      }
      try {
        const response = await fetch(statusUrl);
        if (response.ok) return;
      } catch {
        // ChromeDriver is still starting.
      }
      await sleep(100);
    }
    throw new Error(`ChromeDriver did not become ready.\n${diagnostics()}`);
  } finally {
    child.removeListener('error', recordSpawnError);
  }
}

function collectOutput(child) {
  const output = [];
  const record = (chunk) => {
    output.push(chunk.toString());
    if (output.length > 80) output.shift();
  };
  child.stdout?.on('data', record);
  child.stderr?.on('data', record);
  return () => output.join('').trim();
}

async function resolveStaticFile(urlPath) {
  const relative = decodeURIComponent(urlPath.split('?')[0])
    .replace(/^\/+/, '')
    .replace(/\/$/, '');
  const candidates = relative
    ? [relative, `${relative}.html`, path.join(relative, 'index.html')]
    : ['index.html'];
  for (const candidate of candidates) {
    const absolute = path.resolve(buildRoot, candidate);
    if (!absolute.startsWith(`${buildRoot}${path.sep}`)) continue;
    try {
      await access(absolute);
      return absolute;
    } catch {
      // Try the next clean-URL candidate.
    }
  }
  return path.join(buildRoot, '404.html');
}

async function startFixtureServer() {
  await access(path.join(buildRoot, 'index.html'));
  const server = createHttpServer(async (request, response) => {
    try {
      const absolute = await resolveStaticFile(request.url || '/');
      const body = await readFile(absolute);
      response.writeHead(200, {
        'Cache-Control': 'no-cache',
        'Content-Type':
          mimeTypes.get(path.extname(absolute).toLowerCase()) ??
          'application/octet-stream'
      });
      response.end(body);
    } catch (error) {
      response.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      response.end(error instanceof Error ? error.message : 'Fixture failure');
    }
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') {
    throw new Error('Could not start the mobile acceptance fixture server.');
  }
  return { port: address.port, server };
}

async function closeServer(server) {
  if (!server?.listening) return;
  await new Promise((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve()))
  );
}

function createWebDriver(baseUrl) {
  return async function request(method, pathname, body) {
    const response = await fetch(`${baseUrl}${pathname}`, {
      body: body === undefined ? undefined : JSON.stringify(body),
      headers: body === undefined ? undefined : { 'Content-Type': 'application/json' },
      method
    });
    const payload = await response.json();
    if (!response.ok || payload.value?.error) {
      throw new Error(
        `WebDriver ${method} ${pathname} failed: ${payload.value?.message ?? response.statusText}`
      );
    }
    return payload.value;
  };
}

async function waitForPage(request, sessionId) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const readyState = await request(
      'POST',
      `/session/${sessionId}/execute/sync`,
      { args: [], script: 'return document.readyState;' }
    );
    if (readyState === 'complete') {
      await sleep(250);
      return;
    }
    await sleep(100);
  }
  throw new Error('Homepage did not finish loading for mobile acceptance.');
}

const measurementScript = `
  const rect = (selector) => {
    const element = document.querySelector(selector);
    if (!element) return null;
    const bounds = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return {
      bottom: bounds.bottom,
      display: style.display,
      height: bounds.height,
      left: bounds.left,
      right: bounds.right,
      width: bounds.width
    };
  };
  const gallery = document.querySelector('.device-gallery');
  const galleryItems = [...document.querySelectorAll('.device-gallery__item')];
  const galleryStyle = getComputedStyle(gallery);
  const initialScrollLeft = gallery.scrollLeft;
  gallery.scrollLeft = gallery.scrollWidth;
  const lastItem = galleryItems.at(-1)?.getBoundingClientRect();
  const galleryBounds = gallery.getBoundingClientRect();
  const targetHeights = [
    ...document.querySelectorAll(
      '.mobile-menu-toggle, .web-app-action, .store-badge:not([style*="display: none"]), .hero-github-badge'
    )
  ].filter((element) => getComputedStyle(element).display !== 'none')
    .map((element) => element.getBoundingClientRect().height);
  const result = {
    documentHeight: document.documentElement.scrollHeight,
    gallery: {
      clientWidth: gallery.clientWidth,
      height: galleryBounds.height,
      itemCount: galleryItems.length,
      itemSnap: galleryItems.map(
        (item) => getComputedStyle(item).scrollSnapAlign
      ),
      lastItemReachable: Boolean(
        lastItem && lastItem.right <= galleryBounds.right + 2
      ),
      overflowX: galleryStyle.overflowX,
      scrollSnapType: galleryStyle.scrollSnapType,
      scrollWidth: gallery.scrollWidth
    },
    halo: rect('.hero-stage__backdrop'),
    hero: rect('.home-hero'),
    horizontalExtent: Math.max(
      document.documentElement.scrollWidth,
      document.body.scrollWidth
    ),
    innerWidth,
    leftPhone: rect('.hero-device--left'),
    platformColumns: getComputedStyle(
      document.querySelector('.platform-grid')
    ).gridTemplateColumns.split(' ').length,
    primaryPhone: rect('.hero-device--primary'),
    rightPhone: rect('.hero-device--right'),
    targetHeights
  };
  gallery.scrollLeft = initialScrollLeft;
  return result;
`;

function verifyViewport(viewport, metrics) {
  const failures = [];
  const mobile = viewport.width <= 680;
  const assert = (condition, message) => {
    if (!condition) failures.push(message);
  };

  assert(
    metrics.horizontalExtent <= metrics.innerWidth + 1,
    `horizontal content is ${metrics.horizontalExtent}px wide in a ${metrics.innerWidth}px viewport`
  );
  assert(metrics.primaryPhone, 'primary hero phone is missing');
  assert(
    metrics.primaryPhone.left >= -1 &&
      metrics.primaryPhone.right <= metrics.innerWidth + 1,
    'primary hero phone leaves the viewport'
  );
  assert(
    metrics.targetHeights.every((height) => height >= 44),
    `interactive target below 44px: ${metrics.targetHeights.join(', ')}`
  );

  if (mobile) {
    const haloRatio = metrics.halo.width / metrics.halo.height;
    assert(
      haloRatio >= 0.98 && haloRatio <= 1.02,
      `hero halo ratio is ${haloRatio.toFixed(3)}, expected 1:1`
    );
    assert(metrics.leftPhone.display === 'none', 'left hero phone is visible');
    assert(metrics.rightPhone.display === 'none', 'right hero phone is visible');
    assert(metrics.hero.height <= 1_400, `hero is ${metrics.hero.height}px tall`);
    assert(
      metrics.gallery.height <= 720,
      `mobile gallery is ${metrics.gallery.height}px tall`
    );
    assert(
      metrics.gallery.scrollWidth > metrics.gallery.clientWidth + 10,
      'mobile gallery is not horizontally scrollable'
    );
    assert(
      metrics.gallery.overflowX === 'auto' &&
        metrics.gallery.scrollSnapType.startsWith('x'),
      'mobile gallery is missing native horizontal scroll snapping'
    );
    assert(
      metrics.gallery.itemSnap.every((value) => value === 'start'),
      'one or more gallery cards do not snap to the start edge'
    );
    assert(metrics.gallery.lastItemReachable, 'last gallery card is not reachable');
    assert(metrics.gallery.itemCount === 3, 'mobile gallery duplicated a screenshot');
    assert(
      metrics.platformColumns === (viewport.width >= 360 ? 2 : 1),
      `platform grid has ${metrics.platformColumns} columns`
    );
    assert(
      metrics.documentHeight <= 9_000,
      `mobile homepage is still ${metrics.documentHeight}px tall`
    );
  } else {
    assert(metrics.leftPhone.display !== 'none', 'desktop/tablet left phone is hidden');
    assert(metrics.rightPhone.display !== 'none', 'desktop/tablet right phone is hidden');
    assert(
      metrics.gallery.scrollWidth <= metrics.gallery.clientWidth + 1,
      'desktop/tablet gallery unexpectedly scrolls horizontally'
    );
    assert(metrics.gallery.itemCount === 3, 'desktop/tablet gallery changed card count');
  }

  if (failures.length) {
    throw new Error(`${viewport.name} (${viewport.width}×${viewport.height}):\n- ${failures.join('\n- ')}`);
  }
}

async function runAcceptance() {
  const driverPort = await reserveLoopbackPort();
  const chromeDriver = spawn(
    chromeDriverBinary,
    [`--port=${driverPort}`, '--allowed-ips=127.0.0.1'],
    {
      cwd: repositoryRoot,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe']
    }
  );
  const diagnostics = collectOutput(chromeDriver);
  let fixture;
  let sessionId;
  const stopOnSignal = async () => {
    await terminateChild(chromeDriver);
    await closeServer(fixture?.server);
  };
  process.once('SIGINT', stopOnSignal);
  process.once('SIGTERM', stopOnSignal);

  try {
    await waitForChromeDriver(chromeDriver, driverPort, diagnostics);
    fixture = await startFixtureServer();
    const request = createWebDriver(`http://127.0.0.1:${driverPort}`);
    const chromeOptions = {
      args: ['--headless=new', '--no-sandbox', '--disable-gpu']
    };
    if (process.env.CHROME_BINARY) {
      chromeOptions.binary = process.env.CHROME_BINARY;
    }
    const session = await request('POST', '/session', {
      capabilities: {
        alwaysMatch: {
          browserName: 'chrome',
          'goog:chromeOptions': chromeOptions
        }
      }
    });
    sessionId = session.sessionId;

    for (const viewport of viewports) {
      await request('POST', `/session/${sessionId}/goog/cdp/execute`, {
        cmd: 'Emulation.setDeviceMetricsOverride',
        params: {
          deviceScaleFactor: 1,
          height: viewport.height,
          mobile: false,
          screenHeight: viewport.height,
          screenWidth: viewport.width,
          width: viewport.width
        }
      });
      await request('POST', `/session/${sessionId}/url`, {
        url: `http://127.0.0.1:${fixture.port}/?viewport=${viewport.width}`
      });
      await waitForPage(request, sessionId);
      const metrics = await request(
        'POST',
        `/session/${sessionId}/execute/sync`,
        { args: [], script: measurementScript }
      );
      verifyViewport(viewport, metrics);
      console.log(
        `${viewport.name}: ${Math.round(metrics.hero.height)}px hero, ${Math.round(metrics.gallery.height)}px gallery, ${metrics.documentHeight}px page`
      );
    }
  } finally {
    process.removeListener('SIGINT', stopOnSignal);
    process.removeListener('SIGTERM', stopOnSignal);
    if (sessionId) {
      try {
        const request = createWebDriver(`http://127.0.0.1:${driverPort}`);
        await request('DELETE', `/session/${sessionId}`);
      } catch {
        // ChromeDriver cleanup below is authoritative.
      }
    }
    await closeServer(fixture?.server);
    await terminateChild(chromeDriver);
  }
}

runAcceptance()
  .then(() => console.log('Mobile homepage acceptance passed.'))
  .catch((error) => {
    console.error(
      `Mobile homepage acceptance failed: ${error instanceof Error ? error.stack : error}`
    );
    process.exitCode = 1;
  });
