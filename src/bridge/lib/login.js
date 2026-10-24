// 登录助手：打开一个可见浏览器窗口，登录后自动导出 Cloud cookie 到本地
// 原理：Edge + CDP 监听 /class/apis.json 的成功响应，一旦判定已登录就抓取全部 seewo cookie
const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');

const EDGE_CANDIDATES = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
];

function findBrowser() {
  for (const p of EDGE_CANDIDATES) if (fs.existsSync(p)) return p;
  return null;
}

const sleep = ms => new Promise(r => setTimeout(r, ms));
const httpGet = (u, timeoutMs = 5000, method = 'GET') => new Promise((res, rej) => {
  const req = http.request(u, { method }, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => res(d)); });
  req.on('error', rej);
  req.setTimeout(timeoutMs, () => req.destroy(new Error('timeout')));
  req.end();
});

async function login({ profileDir, cookieFile, startUrl = 'https://m-campus.seewo.com/class/message?action=wxappHome', port = 9336, timeoutMs = 300000, log } = {}) {
  const browser = findBrowser();
  if (!browser) throw new Error('未找到 Edge / Chrome 浏览器');
  if (typeof WebSocket === 'undefined') {
    throw new Error('当前 Node 版本过低（' + process.version + '），登录需要 Node 22 或更高（用到内置 WebSocket）');
  }
  fs.mkdirSync(profileDir, { recursive: true });
  fs.mkdirSync(path.dirname(cookieFile), { recursive: true });

  // ① 端口上已经有调试实例 → 直接复用，不要再 spawn。
  //    同一个 --user-data-dir 再启动时 Chromium 只会把请求转发给已有实例，
  //    新进程立刻退出，界面上就表现为"弹了个空白窗口/什么都没发生"。
  let proc = null;
  let reused = false;
  try {
    const v = JSON.parse(await httpGet(`http://127.0.0.1:${port}/json/version`, 2000));
    if (v && v.Browser) {
      reused = true;
      log && log.warn(`复用已打开的登录窗口（${v.Browser}），不再重复启动`);
    }
  } catch { }

  if (!reused) {
    // ② 清掉上次被强杀留下的单实例锁，否则新窗口可能起不来或是空白页
    for (const f of ['SingletonLock', 'SingletonCookie', 'SingletonSocket', 'lockfile']) {
      try { fs.rmSync(path.join(profileDir, f), { force: true }); } catch { }
    }
    log && log.info('正在打开登录窗口，请在弹出的浏览器里完成登录（扫码或账号密码）…');
    proc = spawn(browser, [
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profileDir}`,
      '--no-first-run', '--no-default-browser-check',
      '--new-window',                          // 强制新窗口，避免复用已有空白窗
      '--hide-crash-restore-bubble',           // 上次异常退出后别弹"恢复页面"，那玩意儿会让内容区空着
      '--disable-session-crashed-bubble',
      '--window-size=1100,860',
      '--ignore-certificate-errors',
      startUrl,
    ], { stdio: 'ignore' });
  }

  const killProc = () => { try { proc && proc.kill(); } catch { } };

  const listTargets = async () => {
    try { return JSON.parse(await httpGet(`http://127.0.0.1:${port}/json/list`)); } catch { return null; }
  };
  const isBlank = u => !u || u === 'about:blank' || u.startsWith('edge://') || u.startsWith('chrome://') || u.startsWith('data:');

  // 先等调试端口起来
  let list = null;
  for (let i = 0; i < 40; i++) {
    await sleep(300);
    list = await listTargets();
    if (list && list.some(t => t.type === 'page')) break;
  }
  if (!list) { killProc(); throw new Error('浏览器调试端口未就绪（窗口可能被拦截或启动失败）'); }

  // ⚠ 关键：Edge 会先开一个 about:blank，几秒后才真正跳转到目标地址。
  //   原来一看到"有 page 目标"就连接，抓到的是空白页 —— 窗口开了、里面啥也没有。
  //   这里必须等到某个页面的 URL 真的落到 seewo 上（最多等 15 秒）。
  let page = (list || []).filter(t => t.type === 'page').find(t => /seewo\.com/i.test(t.url || ''));
  if (!page) {
    for (let i = 0; i < 50 && !page; i++) {
      await sleep(300);
      const l = await listTargets();
      if (!l) continue;
      page = l.filter(t => t.type === 'page').find(t => /seewo\.com/i.test(t.url || ''));
    }
  }
  // 还是没跳过去 → 主动开一个标签页（/json/new 用 PUT）
  if (!page) {
    log && log.warn('等待 15 秒仍未跳到登录页，主动打开一个标签页…');
    try {
      const created = JSON.parse(await httpGet(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(startUrl)}`, 6000, 'PUT'));
      if (created && created.webSocketDebuggerUrl) page = created;
    } catch (e) { log && log.warn(`主动开标签页失败：${e.message}`); }
  }
  if (!page) {
    const any = (await listTargets() || []).find(t => t.type === 'page');
    if (any) page = any;
  }
  if (!page) { killProc(); throw new Error('没有可用的浏览器页面'); }

  const ws = new WebSocket(page.webSocketDebuggerUrl);
  let id = 0; const pending = new Map();
  const send = (m, p = {}) => new Promise(res => { const mid = ++id; pending.set(mid, res); ws.send(JSON.stringify({ id: mid, method: m, params: p })); });

  let authed = false;
  ws.addEventListener('message', ev => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); return; }
    if (m.method === 'Network.responseReceived' && /apis\.json/.test(m.params.response.url) && m.params.response.status === 200) authed = true;
  });
  await new Promise(r => ws.addEventListener('open', r));

  // 兜底：万一还是空白页，就在这个标签页里导航一次
  const href = async () => {
    const r = await send('Runtime.evaluate', { expression: 'location.href', returnByValue: true });
    return (r && r.result && r.result.value) || '';
  };

  let nowUrl = await href();
  // 目标 URL 已登记但文档还在 about:blank，是常见的中间态，必须轮询等它落地
  for (let i = 0; i < 40 && isBlank(nowUrl); i++) { await sleep(300); nowUrl = await href(); }

  if (isBlank(nowUrl)) {
    log && log.warn(`登录窗口仍是空白页（${nowUrl || '空'}），主动导航到登录页…`);
    await send('Page.enable');
    await send('Page.navigate', { url: startUrl });
    for (let i = 0; i < 40 && isBlank(nowUrl); i++) { await sleep(300); nowUrl = await href(); }
  }

  log && log.info(`登录页面已加载：${nowUrl || '(未知)'}`);
  if (isBlank(nowUrl)) {
    ws.close(); killProc();
    throw new Error('登录页未能加载（当前地址 ' + (nowUrl || '空') + '），请检查网络或代理设置');
  }

  await send('Network.enable');

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline && !authed) await sleep(1000);
  if (!authed) { ws.close(); killProc(); throw new Error('登录超时'); }

  // 稍等一下让 cookie 落盘齐全
  await sleep(1500);
  const all = await send('Network.getAllCookies');
  const jar = {};
  for (const c of (all.cookies || [])) {
    if (!/seewo/i.test(c.domain)) continue;
    jar[c.domain] = jar[c.domain] || {};
    jar[c.domain][c.name] = c.value;
  }
  fs.writeFileSync(cookieFile, JSON.stringify(jar, null, 2));
  log && log.info(`登录成功，已保存登录态：${Object.keys(jar).join(', ')}`);

  ws.close();
  killProc();
  return jar;
}

module.exports = { login, findBrowser };
