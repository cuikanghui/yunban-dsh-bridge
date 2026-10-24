// DSH 驱动层（生产版）
// 直接 spawn Electron 主程序（ELECTRON_RUN_AS_NODE=1）跑 cli.js，
// 走 --profile <name> --json 的 NDJSON 事件流，拿 sessionId 与最终回答。
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const credentials = require('./credentials');
const sessionLock = require('./session_lock');

const CANDIDATES = (process.env.DSH_APP_DIR ? [process.env.DSH_APP_DIR] : []).concat([
  path.join(process.env.LOCALAPPDATA || '', 'Programs', 'DeepSeek Harness'),
  path.join(process.env.LOCALAPPDATA || '', 'DeepSeekHarness'),
  'C:\\Program Files\\DeepSeek Harness',
  'D:\\DeepSeekHarness',
  'D:\\Program Files\\DeepSeek Harness',
]);

function findInstall() {
  for (const dir of CANDIDATES) {
    if (!dir) continue;
    const exe = path.join(dir, 'app', 'DeepSeek Harness.exe');
    const asar = path.join(dir, 'app', 'resources', 'app.asar');
    const cli = path.join(dir, 'app', 'resources', 'app.asar', 'dsh', 'node_modules',
      '@deepseek-ai', 'dsh-desktop-host', 'lib', 'cli.js');
    // 注意：cli.js 位于 asar 归档内部，普通 Node 的 existsSync 看不到，只能用 app.asar 判断安装是否完整
    if (fs.existsSync(exe) && fs.existsSync(asar)) return { appDir: dir, exe, asar, cli };
  }
  return null;
}

class DshError extends Error {
  constructor(msg, extra = {}) { super(msg); Object.assign(this, extra); }
}

// 正在跑的 DSH 子进程：桥接退出时要能一起收掉，
// 否则 Electron 子进程会变成孤儿继续跑，占着会话写句柄，
// 下次启动就会撞 "session already owned by an active write handle"。
const running = new Set();

// Windows 上 child.kill() 只结束父进程，Electron 的渲染/工具子进程会残留，
// 必须用 taskkill /T 杀整棵树。
function killTree(child) {
  if (!child || child.exitCode !== null || child.killed) return;
  try {
    if (process.platform === 'win32') {
      spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
    } else {
      child.kill('SIGKILL');
    }
  } catch { try { child.kill(); } catch { } }
}

function killAll() { for (const c of running) killTree(c); }

// 错误分型：决定"该不该重试"，而不是所有失败都无脑重试三次
function classify(msg = '') {
  if (/already owned by an active write handle/i.test(msg)) return 'BUSY';
  if (/no credential|鉴权失败|未授权|api ?key|unauthorized/i.test(msg)) return 'NOAUTH';
  if (/未找到 DeepSeek Harness|ENOENT/i.test(msg)) return 'NOINSTALL';
  if (/DSH 回答超时/.test(msg)) return 'TIMEOUT';
  return 'OTHER';
}

/**
 * 提问并等待回答
 * @param {object} o
 * @param {string} o.prompt
 * @param {string} o.cwd           工作区目录（决定会话归属）
 * @param {string} [o.sessionId]   续接会话
 * @param {string} [o.profile]     DSH profile，默认 yunban
 * @param {number} [o.timeoutMs]
 * @param {(ev)=>void} [o.onEvent]
 * @param {import('child_process').ChildProcess} [o.signalHandle] 用于外部取消
 */
function askOnce({ prompt, cwd, sessionId, profile = 'yunban', timeoutMs = 180000, onEvent } = {}) {
  const inst = findInstall();
  if (!inst) return Promise.reject(new DshError('未找到 DeepSeek Harness 安装目录（可设环境变量 DSH_APP_DIR）'));

  const args = ['--expose-internals', inst.cli, '--profile', profile, '--json'];
  if (sessionId) args.push('--session-id', sessionId);
  args.push(prompt);

  return new Promise((resolve, reject) => {
    let sid = sessionId || null;
    let finalText = '';
    let usage = null;
    let stderr = '';
    let buf = '';
    let done = false;
    let timedOut = false;
    let guard = null;

    // 新版 DSH 的 headless 不会自己读桌面端凭证，这里显式注入（已存在的环境变量优先）
    const env = { ...process.env, ELECTRON_RUN_AS_NODE: '1' };
    try { credentials.injectInto(env); } catch { }

  // cwd（DSH 工作区）不存在时 spawn 会抛 ENOENT，而且错误信息里指的是 exe，
  // 看起来像"没装 DSH"，实际是工作区目录被删了。这里先确保它存在。
  try { fs.mkdirSync(cwd, { recursive: true }); } catch { }

  const child = spawn(inst.exe, args, {
    cwd,
    env,
    windowsHide: true,
  });
    running.add(child);

    const finish = (err, val) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      clearTimeout(guard);
      running.delete(child);
      err ? reject(err) : resolve(val);
    };

    // 逐行解析（抽出来，退出时要把残留的最后一行也处理掉）
    const handleLine = line => {
      const s = String(line).trim();
      if (!s) return;
      let ev;
      try { ev = JSON.parse(s); } catch { return; }
      if (ev.type === 'session' && ev.sessionId) sid = ev.sessionId;
      if (ev.type === 'final') finalText = ev.text || '';
      if (ev.type === 'status' && ev.usage) usage = ev.usage;
      if (onEvent) { try { onEvent(ev); } catch { } }
    };

    const timer = setTimeout(() => {
      timedOut = true;
      // 关键：先把整棵进程树杀掉并等它真的退出，再报超时。
      // 原来 kill 完立刻 reject → 重试马上又起一个进程 → 撞同一个会话写句柄。
      killTree(child);
      guard = setTimeout(() => {
        finish(new DshError(`DSH 回答超时（${Math.round(timeoutMs / 1000)} 秒）`, { code: 'TIMEOUT', sessionId: sid }));
      }, 3000);
    }, timeoutMs);

    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        handleLine(line);
      }
    });

    child.stderr.setEncoding('utf8');
    child.stderr.on('data', d => {
      stderr += d;
      // stderr 只留尾部，避免模型/工具异常刷屏把内存吃满
      if (stderr.length > 16384) stderr = stderr.slice(-8192);
    });
    child.on('error', e => {
      const hint = e.code === 'ENOENT'
        ? `（可执行文件或工作区不存在：exe=${inst.exe}，cwd=${cwd}）`
        : '';
      finish(new DshError('启动 DSH 失败：' + e.message + hint, { code: 'EXIT' }));
    });
    child.on('close', code => {
      // 退出时 buf 里可能还有最后一行（没有换行符结尾），不处理就会丢 final
      if (buf) { handleLine(buf); buf = ''; }
      if (timedOut) {
        return finish(new DshError(`DSH 回答超时（${Math.round(timeoutMs / 1000)} 秒）`, { code: 'TIMEOUT', sessionId: sid }));
      }
      if (code !== 0 && !finalText) {
        return finish(new DshError(`DSH 退出码 ${code}${stderr ? '：' + stderr.slice(-300) : ''}`, { sessionId: sid, stderr, code: 'EXIT' }));
      }
      finish(null, { sessionId: sid, text: finalText, usage, stderr });
    });
  });
}

/** 带重试与退避的提问：按错误类型决定重试策略，并对同一会话加跨进程锁 */
async function ask({ retries = 2, backoffMs = 2000, busyRetries = 5, log, ...opts }) {
  // 同一 session 在同一时刻只能有一个驱动者（不管来自哪个进程）
  let release = null;
  if (opts.sessionId) {
    try {
      const l = await sessionLock.acquire(opts.sessionId, { timeoutMs: 30000, log });
      release = l.release;
      if (log && l.waited > 500) log.info(`同会话的另一路调用刚结束，等了 ${Math.round(l.waited / 100) / 10}s 才拿到锁`);
    } catch (e) {
      e.kind = 'BUSY';
      if (log) log.warn(`拿不到会话锁：${e.message}`);
      throw e;
    }
  }

  const busyWaits = [1500, 3000, 5000, 8000, 10000];   // 会话被占：越等越久，总共约 27s
  let busyUsed = 0;
  let lastErr;
  try {
    for (let attempt = 0; attempt <= retries; attempt++) {
      try {
        return await askOnce(opts);
      } catch (e) {
        lastErr = e;
        const kind = classify(e.message);
        e.kind = kind;
        if (log) log.warn(`DSH 第 ${attempt + 1} 次失败（${kind}）：${e.message}`);

        // 账号/凭证/未安装：重试没有任何意义，只会拖慢并刷日志
        if (kind === 'NOAUTH' || kind === 'NOINSTALL') throw e;

        // 会话被占：可能是 DSH 桌面端正在编辑同一会话，按 1.5→3→5→8→10s 退避重试
        if (kind === 'BUSY') {
          if (busyUsed < busyRetries && busyUsed < busyWaits.length) {
            const w = busyWaits[busyUsed++];
            if (log) log.warn(`会话被占用，${w}ms 后重试（第 ${busyUsed} 次）`);
            await new Promise(r => setTimeout(r, w));
            attempt--;              // BUSY 不占用普通重试次数
            continue;
          }
          throw e;
        }

        // 超时重试一次就够：每次超时都是几十秒到几分钟，重试三次会把用户晾太久
        if (kind === 'TIMEOUT') {
          if (attempt < Math.min(retries, 1)) { await new Promise(r => setTimeout(r, backoffMs)); continue; }
          throw e;
        }
        if (attempt < retries) await new Promise(r => setTimeout(r, backoffMs * Math.pow(2, attempt)));
      }
    }
    throw lastErr;
  } finally {
    if (release) release();
  }
}

module.exports = { ask, askOnce, findInstall, killAll, killTree, classify, DshError };
