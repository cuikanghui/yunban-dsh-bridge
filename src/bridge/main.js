#!/usr/bin/env node
// 云班-DSH 桥接器 · 常驻主程序
// 职责：轮询云班亲情留言 → 交给 DSH 解答 → 把答案回发到对应会话
//
// 用法：
//   node main.js                 常驻运行
//   node main.js --once          只跑一轮就退出（调试用）
//   node main.js --dry-run       不生成本身，只打印将要发送的内容
//   node main.js --simulate="…"  模拟一条留言走完整流程（不读云班）
//   node main.js --login         打开登录窗口，刷新登录态
//   node main.js --status        查看配置、登录态、会话映射等状态
//   node main.js --verbose       输出调试日志

const fs = require('fs');
const os = require('os');
const path = require('path');

const { createLogger } = require('./lib/logger');
const { readJson, writeJson, createStore } = require('./lib/store');
const { createSeewo, AuthError } = require('./lib/seewo');
const dsh = require('./lib/dsh');
const dshWorkspace = require('./lib/dsh_workspace');
const account = require('./lib/account');
const { login } = require('./lib/login');
const cookieShare = require('./lib/cookie_share');
const { detectPeers, accountReport } = require('./lib/peers');

// ---------- 路径 ----------
const ROOT = path.resolve(__dirname, '..');          // 程序根目录（可整体拷贝迁移）
const CONF_DIR = path.join(ROOT, 'config');
const DATA_DIR = path.join(ROOT, 'data');
const LOG_DIR = path.join(DATA_DIR, 'logs');
const CONF_FILE = path.join(CONF_DIR, 'bridge.json');
const COOKIE_FILE = path.join(DATA_DIR, 'session_cookies.json');
const PROFILE_DIR = path.join(DATA_DIR, 'browser-profile');
const STATE_FILE = path.join(DATA_DIR, 'state.json');
const MAP_FILE = path.join(DATA_DIR, 'session_map.json');
const ATTEMPT_FILE = path.join(DATA_DIR, 'attempts.json');
const PENDING_FILE = path.join(DATA_DIR, 'pending.json');   // 处理到一半失败、待补发的消息
const LOCK_FILE = path.join(DATA_DIR, 'bridge.lock');
const STATUS_FILE = path.join(DATA_DIR, 'status.json');   // 给托盘读的实时状态
const FORCE_FILE = path.join(DATA_DIR, 'force-poll');     // 托盘点「立即检查」时写这个文件
const DISABLED_FLAG = path.join(DATA_DIR, 'disabled.flag'); // 存在=整个程序停用（托盘也不会拉起）
const REBIND_FLAG = path.join(DATA_DIR, 'rebind.flag');     // 存在=下一轮强制重新识别账号/班级

// ---------- 参数 ----------
const argv = process.argv.slice(2);
const has = k => argv.includes(k);
const val = k => { const a = argv.find(x => x.startsWith(k + '=')); return a ? a.slice(k.length + 1) : undefined; };

const OPTS = {
  once: has('--once'),
  dryRun: has('--dry-run'),
  simulate: val('--simulate'),
  doLogin: has('--login'),
  status: has('--status'),
  verbose: has('--verbose'),
  rebind: has('--rebind'),      // 强制重新识别账号/班级（账号重新注册后用）
};

// ---------- 配置 ----------
const DEFAULT_CONF = {
  版本: 1,
  云班: {
    classUid: '',
    schoolUid: '',
    userUid: '',
    senderType: 'parent',
    // 同账号的其它云班客户端（命令行关键词）：只用于检测并提示，不影响功能
    同账号客户端: ['QQ云班互联'],
    // 登录成功后把登录态合并同步到这些文件（留空=不同步）
    // 目的：让多个客户端共用同一份 token，避免各自登录互相顶掉
    登录态共享: []
  },
  DSH: {
    profile: 'yunban',
    workspace: '../workspace',
    timeoutMs: 90000,
    retries: 2
  },
  轮询: {
    间隔秒: 60,
    每会话取多少条: 20,
    最大并发: 3,
    单条最大尝试次数: 3
  },
  回复: {
    超时兜底话术: '收到啦，我这边整理一下，稍后回复您～',
    非文本话术: '您好，目前我只能处理文字留言，麻烦用文字再说一次～',
    只处理对方发来的: true
  },
  logLevel: 'info',
  自动登录: false,
  自动登记工作区: false   // 默认关：桥接器不去改 DSH 的 workspace.json（需要时手动打开）
};

function loadConfig() {
  fs.mkdirSync(CONF_DIR, { recursive: true });
  if (!fs.existsSync(CONF_FILE)) writeJson(CONF_FILE, DEFAULT_CONF);
  const raw = readJson(CONF_FILE, {});
  // 浅合并两层，保证新增默认项不丢
  const cfg = { ...DEFAULT_CONF, ...raw };
  for (const k of Object.keys(DEFAULT_CONF)) {
    if (typeof DEFAULT_CONF[k] === 'object' && !Array.isArray(DEFAULT_CONF[k])) cfg[k] = { ...DEFAULT_CONF[k], ...(raw[k] || {}) };
  }
  return cfg;
}

const cfg = loadConfig();
const log = createLogger({ dir: LOG_DIR, level: OPTS.verbose ? 'debug' : (cfg.logLevel || 'info') });
const state = createStore(STATE_FILE);       // peerUid -> 已处理的最大消息 id
const map = createStore(MAP_FILE);           // peerUid -> DSH sessionId
const attempts = createStore(ATTEMPT_FILE);  // 消息 id -> 尝试次数

// ---------- 登录（登录成功后顺带同步登录态给同账号的其它客户端） ----------
function shareLoginState(jar) {
  const targets = (cfg.云班 && cfg.云班.登录态共享) || [];
  if (!targets.length) return;
  const r = cookieShare.syncAll(jar, targets, { log });
  const ok = r.filter(x => x.ok).length;
  log.info(`登录态共享：${ok}/${r.length} 个目标已更新（避免同账号多个客户端互相顶掉）`);
}

async function loginAndShare() {
  const jar = await login({ profileDir: PROFILE_DIR, cookieFile: COOKIE_FILE, log });
  try { shareLoginState(jar); } catch (e) { log.warn(`登录态共享失败：${e.message}`); }
  return jar;
}

// ---------- 账号绑定（运行期可变） ----------
// config 里的 classUid/userUid 只是"上次记住的值"，真正以 cookie 里的账号为准，
// 账号重新注册后可以被自动发现的结果覆盖。
const binding = {
  userUid: cfg.云班.userUid || '',
  classUid: cfg.云班.classUid || '',
  schoolUid: cfg.云班.schoolUid || '',
};
function saveBindingToConfig() {
  const c = cfg.云班;
  if (c.userUid === binding.userUid && c.classUid === binding.classUid && c.schoolUid === binding.schoolUid) return false;
  c.userUid = binding.userUid;
  c.classUid = binding.classUid;
  c.schoolUid = binding.schoolUid;
  try { writeJson(CONF_FILE, cfg); } catch (e) { log.warn(`写回配置失败：${e.message}`); }
  return true;
}

/**
 * 确保账号与班级是最新的：
 *  1) cookie 里的 userId 变了 → 判定账号变更，丢弃旧 classUid，强制重新发现
 *  2) classUid 为空或 force → 调接口自动发现
 *  3) 有变化就写回 config
 */
async function ensureBinding(reason, { force = false } = {}) {
  let changed = false;
  const id = account.readIdentity(COOKIE_FILE);

  if (id.userId && binding.userUid && id.userId !== binding.userUid) {
    log.warn(`检测到账号变更：${binding.userUid} → ${id.userId}${id.userName ? `（${id.userName}）` : ''}`);
    binding.userUid = id.userId;
    binding.classUid = '';                       // 旧班级对新账号无效，必须重新发现
    changed = true;
  }
  if (!binding.userUid && id.userId) { binding.userUid = id.userId; changed = true; }
  if (!binding.schoolUid && id.schoolUid) { binding.schoolUid = id.schoolUid; changed = true; }

  if (!binding.userUid) {
    log.error('登录态里没有账号信息，无法绑定。请右键托盘「重新登录」。');
    return { ok: false, reason: 'no-identity' };
  }

  if (!binding.classUid || force) {
    log.info(`正在自动发现账号 ${binding.userUid} 的班级/会话…${reason ? `（触发原因：${reason}）` : ''}`);
    const d = await account.discoverClasses({ seewo, userId: binding.userUid, log });
    if (d.classes.length) {
      const first = d.classes[0];
      binding.classUid = first.classUid;
      if (first.schoolUid) binding.schoolUid = first.schoolUid;
      changed = true;
      log.info(`已发现 ${d.classes.length} 个班级，选用 classUid=${first.classUid}`
        + `${first.className ? `（${first.className}）` : ''}，来源 ${d.source}`);
      if (d.classes.length > 1) {
        log.info('其余班级：' + d.classes.slice(1).map(c => `${c.classUid}${c.className ? `(${c.className})` : ''}`).join('，'));
      }
    } else if (d.authFail) {
      log.error('自动发现被拒绝：登录态无效或账号已被重新注册。请右键托盘「重新登录」后会自动重新建立桥接。');
      statusInfo.状态 = 'need-login';
      statusInfo.最后错误 = '登录态无效，需要重新登录';
      writeStatus();
      return { ok: false, reason: 'auth' };
    } else {
      log.warn('没能自动发现班级，继续使用配置里的 classUid。若会话对不上，请右键「重新登录」。');
    }
  }

  if (changed && saveBindingToConfig()) {
    log.info(`绑定已更新并写回 config：userUid=${binding.userUid} classUid=${binding.classUid}`);
  }
  return { ok: !!binding.classUid, binding };
}

const pending = createStore(PENDING_FILE);   // 消息 id -> 待补发的任务（发送失败时写入）

const workspace = path.isAbsolute(cfg.DSH.workspace) ? cfg.DSH.workspace : path.resolve(__dirname, cfg.DSH.workspace);
const seewo = createSeewo({ cookieFile: COOKIE_FILE, log });

// ---------- 状态文件（供托盘读取） ----------
const statusInfo = {
  状态: 'starting',
  启动时间: new Date().toISOString(),
  最后轮询: null,
  最后轮询摘要: '',
  最后消息: null,
  最后错误: null,
  进行中: 0,
  队列: 0,
  已建会话: 0,
  轮询间隔秒: cfg.轮询.间隔秒,
  演练模式: OPTS.dryRun,
  pid: process.pid,
};

function writeStatus() {
  try {
    statusInfo.进行中 = active;
    statusInfo.队列 = queue.length;
    statusInfo.已建会话 = Object.keys(map.all).length;
    writeJson(STATUS_FILE, { ...statusInfo, 更新时间: new Date().toISOString() });
  } catch { /* 状态写入失败不影响主流程 */ }
}

// ---------- 单实例锁 ----------
function acquireLock() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  if (fs.existsSync(LOCK_FILE)) {
    const pid = Number(fs.readFileSync(LOCK_FILE, 'utf8').trim());
    if (pid && isAlive(pid)) {
      log.error(`已有实例在运行（PID ${pid}），本次退出。如确认没有运行，请删除 ${LOCK_FILE}`);
      process.exit(1);
    }
    log.warn('发现残留锁文件，已清理');
  }
  fs.writeFileSync(LOCK_FILE, String(process.pid));
}
function isAlive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}
function releaseLock() {
  try {
    if (Number(fs.readFileSync(LOCK_FILE, 'utf8').trim()) === process.pid) fs.unlinkSync(LOCK_FILE);
  } catch { }
}

// ---------- 并发队列 ----------
let active = 0;
const queue = [];
const queuedIds = new Set();

function enqueue(job) {
  if (queuedIds.has(job.msgId)) return;
  queuedIds.add(job.msgId);
  queue.push(job);
  pump();
}

function pump() {
  while (active < (cfg.轮询.最大并发 || 3) && queue.length) {
    const job = queue.shift();
    active++;
    // 同一个家长/孩子的多条消息必须串行：
    // DSH 的同一个 session 同时只能有一个写入句柄，并发会报
    // "session ... is already owned by an active write handle"
    withPeerLock(job.peerUid, () => handle(job))
      .catch(e => log.error(`处理消息 ${job.msgId} 异常：${e.message}`))
      .finally(() => {
        active--;
        queuedIds.delete(job.msgId);
        pump();
      });
  }
  if (active === 0 && queue.length === 0) maybeIdleHint();
  writeStatus();
}

// ---------- 按会话串行 ----------
const peerChains = new Map();
function withPeerLock(peerUid, fn) {
  const prev = peerChains.get(peerUid) || Promise.resolve();
  const next = prev.then(fn, fn);
  peerChains.set(peerUid, next.catch(() => { }));
  return next;
}

let idleHinted = false;
function maybeIdleHint() {
  if (idleHinted) return;
  idleHinted = true;
  setTimeout(() => { idleHinted = false; }, 500);
}

// ---------- 消息 ID 比较 ----------
// 云班的消息 ID 是 19 位纯数字，超出 JS Number 的安全整数范围（2^53），
// 必须全程用字符串比较：长度不同时长的更新，长度相同时按字典序（纯数字等效于数值序）。
function normId(v) {
  const s = String(v ?? '').trim();
  return /^\d+$/.test(s) ? s : null;
}
function isNewerId(id, last) {
  if (!last) return true;
  if (id.length !== last.length) return id.length > last.length;
  return id > last;
}
function maxId(a, b) {
  if (!a) return b;
  if (!b) return a;
  return isNewerId(a, b) ? a : b;
}

// ---------- 回发长度限制 ----------
// 云班接口硬限制：留言内容不能超过 200 字符，超了直接拒发（[POST_KIDNOTE_V1_NOTE] 留言内容不能超过200字符）。
// 这里统一做收口：按码点计数，超长时在句末标点处截断并补省略号。
const MAX_REPLY_CHARS = 190;   // 留 10 字余量：emoji 在服务端可能按 2 个字符算

// 班牌是纯文本，Markdown 会原样显示（**加粗** 变星号），发之前先洗干净
function stripMarkdown(t) {
  return String(t ?? '')
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/__(.+?)__/g, '$1')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/^#{1,6}\s*/gm, '')
    .replace(/^\s*[-*+]\s+/gm, '· ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function clampAnswer(text) {
  const raw = String(text ?? '').replace(/\r/g, '').trim();
  const chars = Array.from(raw);
  if (chars.length <= MAX_REPLY_CHARS) return { text: raw, truncated: false };

  const head = chars.slice(0, MAX_REPLY_CHARS).join('');
  // 尽量在最后一个句末标点处断开，读起来自然
  const m = head.match(/^[\s\S]*[。！？!?～~…\n]/);
  let body = (m ? m[0] : head).trim();
  body = body.replace(/[，、；：,;:]+$/, '').trim();
  return { text: body + '…', truncated: true };
}

// ---------- 单条消息处理 ----------
async function handle({ peerUid, peerName, classUid, schoolUid, msgId, content, msgType, kind, hasVoice, hasAttach, senderName }) {
  const tag = `[${peerName || peerUid}] 消息 ${msgId}`;
  log.info(`${tag} 收到${kind === 'text' ? '' : '（非文字）'}：${String(content ?? '').slice(0, 60)}`);

  let answer;
  if (kind !== 'text') {
    answer = cfg.回复.非文本话术;
    log.warn(`${tag} 非文字消息（type=${msgType} kind=${kind} voice=${!!hasVoice} attach=${!!hasAttach}），走兜底话术`);
  } else {
    const sid = map.get(peerUid);
    try {
      const r = await dsh.ask({
        prompt: composePrompt(content),
        cwd: workspace,
        sessionId: sid,
        profile: cfg.DSH.profile,
        timeoutMs: cfg.DSH.timeoutMs,
        retries: cfg.DSH.retries,
        log,
        onEvent: ev => {
          if (ev.type === 'status' && ev.phase === 'step_start') log.debug(`${tag} DSH 开始思考…`);
        },
      });
      answer = (r.text || '').trim();
      if (r.sessionId && r.sessionId !== sid) {
        map.set(peerUid, r.sessionId);
        log.info(`${tag} 已建立/更新 DSH 会话：${r.sessionId}`);
        // 把新会话登记到「云班」工作区（默认关闭，避免和 DSH 桌面端抢 workspace.json）
        if (cfg.自动登记工作区) {
          dshWorkspace.registerSession(r.sessionId, { title: '云班', dir: cfg.DSH.workspace })
            .catch(e => log.warn(`${tag} 登记到云班工作区失败：${e.message}`));
        }
      }
      log.info(`${tag} DSH 回答 ${answer.length} 字${r.usage ? `（${r.usage.totalTokens} tokens）` : ''}`);    } catch (e) {
      const n = (attempts.get(msgId, 0) || 0) + 1;
      attempts.set(msgId, n);
      if (n >= (cfg.轮询.单条最大尝试次数 || 3)) {
        log.error(`${tag} 已失败 ${n} 次，改用兜底话术`);
        answer = cfg.回复.超时兜底话术;
      } else {
        log.warn(`${tag} 第 ${n} 次失败（${e.message}），下一轮重试`);
        // 和发送失败一样记进待补发队列：
        // 只靠"不推进 state"不够，后面一条成功会把游标推过去，这条就被跳过了
        pending.set(msgId, {
          peerUid, peerName, classUid, schoolUid, msgId, content,
          msgType, kind, hasVoice, hasAttach, senderName,
          tries: n,
          error: e.message,
          failedAt: new Date().toISOString(),
        });
        return;   // 不推进 state，下轮重试
      }
    }
  }

  // 长度收口：云班硬限制 200 字符，超了会被拒发；顺便洗掉 Markdown 记号
  const cleaned = stripMarkdown(answer);
  const clamped = clampAnswer(cleaned);
  if (clamped.truncated) {
    log.warn(`${tag} 回答 ${Array.from(cleaned).length} 字超过上限，已截断到 ${Array.from(clamped.text).length} 字`);
  }
  answer = clamped.text;

  // 发送
  if (OPTS.dryRun) {
    log.info(`${tag} [演练] 将回复：${answer}`);
  } else {
    try {
      const res = await seewo.sendNote({
        schoolUid: schoolUid || binding.schoolUid,
        classUid: classUid || binding.classUid,
        senderUid: binding.userUid,
        receiverUid: peerUid,
        senderType: cfg.云班.senderType,
        type: 1,
        content: answer,
      });
      log.info(`${tag} 已回发：${res.message}`);
    } catch (e) {
      if (e.code === 'AUTH') return onAuthLost(e);
      // 发送失败：进度不能推进，且必须记到待补发队列，
      // 否则「后面一条发送成功」会把 state 推到更大 id，这条就永久丢了
      pending.set(msgId, {
        peerUid, peerName, classUid, schoolUid, msgId, content,
        msgType, kind, hasVoice, hasAttach, senderName,
        tries: (attempts.get(msgId, 0) || 0) + 1,
        error: e.message,
        failedAt: new Date().toISOString(),
      });
      log.error(`${tag} 回发失败：${e.message}（已记入待补发队列，下轮重试）`);
      return;
    }
  }

  const numericId = normId(msgId);
  if (numericId) {
    state.set(peerUid, maxId(state.get(peerUid, ''), numericId));
    attempts.del(msgId);
    pending.del(msgId);       // 补发成功，出队
  }
  statusInfo.最后消息 = `${peerName || peerUid}：${String(content).slice(0, 40)}`;
  writeStatus();
  // 模拟消息（非数字 ID）不写进度，避免污染真实状态
}

// 直接把用户说的话原样交给 DSH —— 不加"来自某某的留言"这类包装。
// 原因：包装会把对话变成"两个人转述第三个人"，模型会去点评转述内容；
// 而实际只有两方：云班用户 ←→ AI。长度/渠道等约束统一放在 yunban 人设里。
function composePrompt(content) {
  return String(content ?? '').trim();
}

// ---------- 轮询 ----------
let paused = false;
let polling = false;

async function pollOnce() {
  if (paused || polling) return;
  polling = true;
  const t0 = Date.now();
  try {
    // 手动请求重新识别（托盘「重新识别账号」/ bat rebind 写这个标记）
    if (fs.existsSync(REBIND_FLAG)) {
      try { fs.unlinkSync(REBIND_FLAG); } catch { }
      log.info('收到「重新识别账号」请求，清空班级绑定后重新发现…');
      binding.classUid = '';
      await ensureBinding('手动重新识别', { force: true });
    }
    // 先补发上次失败的消息：它们的 id 通常已经小于 state 里的进度，
    // 只靠下面的增量扫描会永远漏掉，必须显式重新入队。
    let retried = 0;
    for (const [id, job] of Object.entries(pending.all)) {
      if (queuedIds.has(id)) continue;
      const maxTries = (cfg.轮询.单条最大尝试次数 || 3) * 2;
      if ((job.tries || 0) > maxTries) {
        log.error(`消息 ${id} 连续失败 ${job.tries} 次，放弃补发：${job.error || ''}`);
        pending.del(id);
        continue;
      }
      enqueue({ ...job, msgId: id });
      retried++;
    }
    if (retried) log.info(`补发上次失败的消息 ${retried} 条`);

    // 每轮先对一次账号身份：账号重新注册后 cookie 会变，这里能立刻发现
    if (!binding.classUid) {
      const ensured = await ensureBinding('轮询前班级为空');
      if (!ensured.ok) return;
    } else {
      const id = account.readIdentity(COOKIE_FILE);
      if (id.userId && id.userId !== binding.userUid) {
        await ensureBinding('cookie 里的账号变了');
        if (!binding.classUid) return;
      }
    }

    const dialogs = await seewo.listDialogs({ classUid: binding.classUid, userUid: binding.userUid });
    let found = 0;
    for (const conv of dialogs) {
      const peerUid = conv.userUid || conv.uid;
      if (!peerUid) continue;
      const notes = await seewo.listNotes({
        selfUid: binding.userUid,
        peerUid,
        pageSize: cfg.轮询.每会话取多少条,
      });
      const lastId = String(state.get(peerUid, ''));
      for (const m of notes) {
        const mid = normId(m.id);
        if (!mid) continue;
        if (!isNewerId(mid, lastId)) continue;
        if (cfg.回复.只处理对方发来的 && m.senderUid === binding.userUid) {
          // 自己发的（例如本程序回发的）直接标记，避免反复处理
          state.set(peerUid, maxId(state.get(peerUid, ''), mid));
          continue;
        }
        found++;
        // ⚠ 注意：云班的 type 字段**不是**内容类型！
        //   实测：对方发来的纯文字留言 type=0，本程序发出的 type=1。
        //   判断"能不能当文字处理"只能看 content 与附件字段（voiceUrl / resUrl / resFileKey）。
        const textBody = typeof m.content === 'string' ? m.content.trim() : '';
        const hasVoice = !!(m.voiceUrl && String(m.voiceUrl).trim());
        const hasAttach = !!(m.resUrl && String(m.resUrl).trim()) || !!(m.resFileKey && String(m.resFileKey).trim());
        const kind = textBody ? 'text' : (hasVoice ? 'voice' : (hasAttach ? 'file' : 'unknown'));

        enqueue({
          peerUid,
          peerName: conv.userName || conv.className,
          classUid: conv.classUid || m.classUid,
          schoolUid: m.schoolUid,
          msgId: mid,
          content: m.content,
          msgType: m.type,
          kind,
          hasVoice,
          hasAttach,
          senderName: m.senderName,
        });
      }
    }
    log.info(`轮询完成：会话 ${dialogs.length} 个，新留言 ${found} 条，用时 ${Date.now() - t0}ms，队列 ${queue.length}`);
    statusInfo.最后轮询 = new Date().toISOString();
    statusInfo.最后轮询摘要 = `会话 ${dialogs.length} 个 / 新留言 ${found} 条 / ${Date.now() - t0}ms`;
    statusInfo.最后错误 = null;
    writeStatus();
  } catch (e) {
    if (e.code === 'AUTH') return onAuthLost(e);
    log.error(`轮询失败：${e.message}`);
    statusInfo.最后错误 = e.message;
    writeStatus();
  } finally {
    polling = false;
  }
}

// ---------- 登录态失效 ----------
let authHandled = false;
async function onAuthLost(e) {
  if (authHandled) return;
  authHandled = true;
  paused = true;
  statusInfo.状态 = 'need-login';
  statusInfo.最后错误 = '登录态失效/账号已变更';
  writeStatus();
  log.error(`登录态失效：${e.message}`);
  log.error('这通常意味着账号被重新注册、密码被改或会话过期。'
    + '右键托盘「重新登录」；登录完成后程序会自动重新发现班级和会话，不需要手工改配置。');

  // 掉线时先看是不是"另一个客户端用了同一个账号"导致的
  try {
    const report = accountReport(binding.userUid, cfg.云班.其它客户端登录态 || []);
    const same = report.filter(r => r.ok && r.same);
    if (same.length) {
      const shared = (cfg.云班.登录态共享 || []).length;
      log.warn(`另一个云班客户端用的是同一个账号（${same.map(r => r.uid.slice(0, 10) + '…').join('、')}）`
        + (shared ? '，已开启登录态共享，可能是对方重新登录导致的正常轮换'
          : '。两边各自登录必然互相顶掉，建议让其中一个换账号（见 README「多客户端共存」）'));
    }
  } catch { }
  if (cfg.自动登录) {
    try {
      log.info('按配置自动打开登录窗口…');
      await loginAndShare();
      log.info('登录完成，重新识别账号…');
      const r = await ensureBinding('重新登录后', { force: true });
      log.info(r.ok
        ? `已恢复：classUid=${binding.classUid}，恢复轮询`
        : '登录后仍未找到班级，请检查该账号是否已加入班级');
    } catch (err) {
      log.error(`自动登录失败：${err.message}，请手动执行 --login`);
    }
  } else {
    log.warn('请右键托盘「重新登录」，或执行 `node main.js --login`；在此之前暂停轮询');
  }
  paused = false;
  authHandled = false;
  statusInfo.状态 = 'running';
  writeStatus();
}

// ---------- 状态 ----------
function printStatus() {
  const inst = dsh.findInstall();
  const dlg = (() => { try { return Object.keys(readJson(MAP_FILE, {})).length; } catch { return 0; } })();
  console.log('—— 云班-DSH 桥接器 状态 ——');
  console.log('程序根目录 :', ROOT);
  console.log('配置文件   :', CONF_FILE, fs.existsSync(CONF_FILE) ? '✅' : '❌');
  console.log('登录态     :', COOKIE_FILE, fs.existsSync(COOKIE_FILE) ? '✅' : '❌（需 --login）');
  console.log('DSH        :', inst ? inst.appDir + ' ✅' : '❌ 未找到（可设 DSH_APP_DIR）');
  console.log('DSH profile:', cfg.DSH.profile);
  console.log('工作区     :', workspace, fs.existsSync(workspace) ? '✅' : '❌ 不存在');
  console.log('云班参数   : classUid=' + (cfg.云班.classUid || '未配置') + '  userUid=' + (cfg.云班.userUid || '未配置'));
  const id = account.readIdentity(COOKIE_FILE);
  if (id.userId) {
    const same = id.userId === cfg.云班.userUid;
    console.log('登录态账号 :', id.userId + (id.userName ? `（${id.userName}）` : '')
      + (same ? ' ✅ 与配置一致' : ' ⚠ 与配置不一致，启动时会自动切换'));
  }
  console.log('轮询间隔   :', cfg.轮询.间隔秒 + 's', ' 最大并发:', cfg.轮询.最大并发);
  console.log('已建会话   :', dlg, '个（' + MAP_FILE + '）');
  console.log('总开关     :', fs.existsSync(DISABLED_FLAG) ? '⏸ 已停用（data\\disabled.flag）' : '▶ 启用');
  console.log('运行模式   :', OPTS.dryRun ? '演练（不回发）' : '正常（会真实回发）');
}

// ---------- 主流程 ----------
let stopping = false;

async function main() {
  if (OPTS.status) { printStatus(); return; }

  if (OPTS.doLogin) {
    await loginAndShare();
    return;
  }

  // 总开关：data\disabled.flag 存在则完全不启动（托盘也会遵守）
  // --once / --simulate 属于手动调试，允许越过开关
  if (fs.existsSync(DISABLED_FLAG) && !OPTS.once && !OPTS.simulate) {
    log.info('桥接器处于【停用】状态（data\\disabled.flag 存在），本次不启动。');
    log.info('要恢复：右键托盘 →「启用桥接」，或删除该文件后执行 云班桥接器.bat on');
    return;
  }

  // 启动自检
  // 账号身份以登录态为准：config 里的 classUid/userUid 允许为空，会自动发现后写回
  if (!fs.existsSync(COOKIE_FILE)) {
    log.error(`缺少登录态 ${COOKIE_FILE}，请先执行：node main.js --login`);
    process.exit(2);
  }
  const inst = dsh.findInstall();
  if (!inst) { log.error('未找到 DeepSeek Harness，可设环境变量 DSH_APP_DIR'); process.exit(2); }
  fs.mkdirSync(workspace, { recursive: true });

  acquireLock();
  process.on('exit', releaseLock);
  process.on('SIGINT', () => shutdown('收到 Ctrl+C'));
  process.on('SIGTERM', () => shutdown('收到终止信号'));

  log.info('════════ 云班-DSH 桥接器 启动 ════════');

  // 同账号客户端并存检测（只提示，不阻止）
  try {
    const keywords = cfg.云班.同账号客户端 || [];
    const peers = await detectPeers(keywords);
    const report = accountReport(binding.userUid, cfg.云班.其它客户端登录态 || []);
    const sameAcct = report.filter(r => r.ok && r.same);
    const diffAcct = report.filter(r => r.ok && !r.same);

    if (sameAcct.length) {
      const shared = (cfg.云班.登录态共享 || []).length;
      log.warn(`检测到另一个客户端用的是同一个云班账号：${sameAcct.map(r => r.uid.slice(0, 10) + '…').join('、')}`);
      log.warn(shared
        ? `已开启登录态共享（${shared} 个目标），两边共用同一份 token`
        : '两个程序各自登录会互相顶掉（40105/9999）。要么开启 登录态共享，要么让其中一个换账号。');
    } else if (diffAcct.length) {
      log.info(`其它云班客户端使用不同账号（${diffAcct.map(r => r.uid.slice(0, 10) + '…').join('、')}），登录态互不影响`);
    }
    if (peers.length && !report.length) {
      log.info(`检测到其它云班客户端在运行（${[...new Set(peers.map(p => p.label || p.name))].join('、')}），登录态各用各的`);
    }
  } catch { }

  log.info(`DSH: ${inst.appDir} | profile=${cfg.DSH.profile}`);
  log.info(`工作区: ${workspace}`);
  log.info(`模式: ${OPTS.dryRun ? '演练（不回发）' : '正常（会真实回发）'} | 间隔 ${cfg.轮询.间隔秒}s | 并发 ${cfg.轮询.最大并发}`);
  statusInfo.状态 = 'running';
  writeStatus();

  // 启动时对齐账号/班级：账号重新注册后这里会自动切换
  if (OPTS.rebind || fs.existsSync(REBIND_FLAG)) {
    if (fs.existsSync(REBIND_FLAG)) { try { fs.unlinkSync(REBIND_FLAG); } catch { } }
    log.info('强制重新识别账号与班级');
    binding.classUid = '';
  }
  const ensured = await ensureBinding('启动');
  if (!ensured.ok && ensured.reason === 'auth') {
    log.error('账号未授权，暂停轮询。右键托盘「重新登录」后会自动恢复并重新建立桥接。');
    statusInfo.状态 = 'need-login';
    writeStatus();
    if (!OPTS.once) {
      // 保持进程存活，等用户重新登录后由托盘重启或下一轮自检恢复
      log.info('进程继续驻留，等待登录态更新…');
    }
  } else {
    log.info(`绑定：userUid=${binding.userUid} classUid=${binding.classUid || '(未确定)'}`);
  }

  // 确保「云班工作区」在 DSH 里存在（幂等）
  if (cfg.自动登记工作区) {
    try {
      if (dshWorkspace.isDshRunning()) {
        log.info('检测到 DSH 桌面端正在运行：本次不写 workspace.json，新增会话先排队');
      }
      const wsId = await dshWorkspace.ensureWorkspace({ title: '云班', dir: cfg.DSH.workspace });
      log.info(`云班工作区已就绪：${cfg.DSH.workspace}（id ${wsId}）`);
      const n = await dshWorkspace.flushPending();
      if (n) log.info(`已补登记 ${n} 个排队中的会话`);
    } catch (e) {
      log.warn(`检查/创建云班工作区失败：${e.message}`);
    }
  } else {
    log.info('自动登记工作区已关闭：本程序不会读写 DSH 的 workspace.json');
  }

  // 模拟留言
  if (OPTS.simulate) {
    enqueue({
      peerUid: cfg.云班.userUid,
      peerName: '（模拟）',
      classUid: cfg.云班.classUid,
      schoolUid: cfg.云班.schoolUid,
      msgId: 'sim-' + Date.now(),
      content: OPTS.simulate,
      msgType: 1,
      kind: 'text',
      senderName: '家长',
    });
    await new Promise(r => setTimeout(r, 1500));
    if (OPTS.dryRun) { await waitIdle(120000); shutdown('模拟完成'); return; }
  }

  if (OPTS.once) {
    await pollOnce();
    await waitIdle(300000);
    shutdown('单轮完成');
    return;
  }

  // 常驻循环
  await pollOnce();
  // 常驻循环：这两个定时器是进程活下去的唯一理由，**不能 unref**
  // （之前 unref 过，导致首次轮询后事件循环为空、进程直接退出）
  setInterval(() => { if (!stopping) pollOnce(); }, Math.max(10, cfg.轮询.间隔秒) * 1000);

  // 托盘「立即检查」：发现触发文件就立刻补跑一轮
  setInterval(() => {
    if (stopping) return;
    try {
      if (fs.existsSync(FORCE_FILE)) {
        fs.unlinkSync(FORCE_FILE);
        log.info('收到「立即检查」请求，立刻执行一轮');
        pollOnce();
      }
    } catch { }
  }, 2000);

  // 保持进程存活
  await new Promise(() => { });
}

function waitIdle(ms) {
  return new Promise(resolve => {
    const t0 = Date.now();
    const tick = () => {
      if ((active === 0 && queue.length === 0) || Date.now() - t0 > ms) return resolve();
      setTimeout(tick, 500);
    };
    tick();
  });
}

function shutdown(reason) {
  if (stopping) return;
  stopping = true;
  statusInfo.状态 = 'stopped';
  writeStatus();
  log.info(`准备退出（${reason}），等待进行中的任务…`);
  const t0 = Date.now();
  const tick = () => {
    if (active === 0 || Date.now() - t0 > 20000) {
      // 把还在跑的 DSH 子进程一起收掉：
      // 否则 Electron 子进程会成为孤儿继续写会话，下次启动撞 "already owned"
      try { dsh.killAll(); } catch { }
      log.info(`════════ 桥接器已停止（剩余任务 ${active} 个）════════`);
      log.close();
      process.exit(0);
    }
    setTimeout(tick, 500);
  };
  tick();
}

main().catch(e => {
  log.error('启动失败：' + (e && e.stack ? e.stack : e));
  log.close();
  process.exit(1);
});
