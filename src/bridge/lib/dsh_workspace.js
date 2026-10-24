// 把桥接器新建的 DSH 会话登记到指定工作区（默认 D:\云班 / 云班）
// DSH 的 headless 模式不会自动把会话写进 workspace.json，需要我们自己补登记。
// 写入采用「锁 + 临时文件 + 原子替换」，避免和 GUI 并发写把文件写坏。
const fs = require('fs');
const os = require('os');
const path = require('path');

const DSH_HOME = path.join(os.homedir(), '.dsh');
const WORKSPACE_JSON = path.join(DSH_HOME, 'storages', 'workspace.json');
const LOCK = WORKSPACE_JSON + '.lock';
const PENDING = path.join(__dirname, '..', '..', 'data', 'pending_sessions.json');

// DSH 桌面端是否在运行（有主进程就说明 GUI 开着）
// GUI 运行时它在内存里持有工作区数据，我们并发写容易被它回写覆盖，
// 所以此时只排队、不落盘，等 GUI 关掉再补写。
function isDshRunning() {
  try {
    const { execSync } = require('child_process');
    const out = execSync('tasklist /FI "IMAGENAME eq DeepSeek Harness.exe"', { encoding: 'latin1', timeout: 5000 });
    return /DeepSeek Harness\.exe/i.test(out);
  } catch { return false; }
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// 路径归一化：统一反斜杠、去尾部斜杠、转小写
// 注意：配置里常写 D:/云班，而 DSH 存的是 D:\云班，不归一化会被当成两个不同工作区
function normPath(s) {
  return (s || '').replace(/\//g, '\\').replace(/\\+$/, '').toLowerCase();
}

async function withLock(fn, { retries = 20, waitMs = 100 } = {}) {
  let fd = null;
  for (let i = 0; i < retries; i++) {
    try {
      fd = fs.openSync(LOCK, 'wx');
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      // 残留锁：超过 5 秒视为失效
      try {
        const st = fs.statSync(LOCK);
        if (Date.now() - st.mtimeMs > 5000) fs.unlinkSync(LOCK);
      } catch { }
      await sleep(waitMs);
    }
  }
  if (fd === null) throw new Error('获取 workspace.json 锁超时');
  try {
    return await fn();
  } finally {
    try { fs.closeSync(fd); } catch { }
    try { fs.unlinkSync(LOCK); } catch { }
  }
}

function readWs() {
  return JSON.parse(fs.readFileSync(WORKSPACE_JSON, 'utf8'));
}

function writeWs(obj) {
  const tmp = WORKSPACE_JSON + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), 'utf8');
  fs.renameSync(tmp, WORKSPACE_JSON);
}

/** 找到或创建目标工作区，返回 workspaceId */
async function ensureWorkspace({ title = '云班', dir = 'D:\\云班' } = {}) {
  return withLock(() => {
    const j = readWs();
    const norm = normPath;
    let id = Object.keys(j.tables.workspaces).find(k => norm(j.tables.workspaces[k].path) === norm(dir));
    if (id) return id;
    id = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
      const r = Math.random() * 16 | 0;
      return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
    });
    j.tables.workspaces[id] = { path: dir, title, sessionIds: [], createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
    j.global.workspaceIds = j.global.workspaceIds || [];
    j.global.workspaceIds.push(id);
    writeWs(j);
    return id;
  });
}

/** 把待登记的会话记到队列里（GUI 开着时用） */
function queuePending(sessionId, opts) {
  try {
    fs.mkdirSync(path.dirname(PENDING), { recursive: true });
    let list = [];
    try { list = JSON.parse(fs.readFileSync(PENDING, 'utf8')); } catch { }
    if (!list.some(x => x.sessionId === sessionId)) {
      list.push({ sessionId, title: opts.title, dir: opts.dir, at: new Date().toISOString() });
      fs.writeFileSync(PENDING, JSON.stringify(list, null, 2), 'utf8');
    }
  } catch { }
}

/** GUI 关闭后把队列里的会话补写进 workspace.json */
async function flushPending() {
  if (!fs.existsSync(PENDING)) return 0;
  let list = [];
  try { list = JSON.parse(fs.readFileSync(PENDING, 'utf8')); } catch { return 0; }
  if (!list.length) return 0;
  const rest = [];
  let ok = 0;
  for (const it of list) {
    try {
      await registerSession(it.sessionId, { title: it.title || '云班', dir: it.dir });
      ok++;
    } catch { rest.push(it); }
  }
  fs.writeFileSync(PENDING, JSON.stringify(rest, null, 2), 'utf8');
  return ok;
}

/** 把会话登记进目标工作区（幂等）；GUI 运行中则排队 */
async function registerSession(sessionId, { title = '云班', dir = 'D:\\云班' } = {}) {
  if (!sessionId) return false;
  if (isDshRunning()) { queuePending(sessionId, { title, dir }); return 'deferred'; }
  return withLock(() => {
    const j = readWs();
    const norm = normPath;
    let id = Object.keys(j.tables.workspaces).find(k => norm(j.tables.workspaces[k].path) === norm(dir));
    if (!id) {
      id = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
        const r = Math.random() * 16 | 0;
        return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
      });
      j.tables.workspaces[id] = { path: dir, title, sessionIds: [], createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
      j.global.workspaceIds = j.global.workspaceIds || [];
      j.global.workspaceIds.push(id);
    }
    const ws = j.tables.workspaces[id];
    ws.sessionIds = ws.sessionIds || [];
    if (ws.sessionIds.includes(sessionId)) return false;   // 已登记
    ws.sessionIds.push(sessionId);
    ws.updatedAt = new Date().toISOString();
    writeWs(j);
    return true;
  });
}

module.exports = { ensureWorkspace, registerSession, flushPending, isDshRunning, WORKSPACE_JSON };
