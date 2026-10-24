// 回路自检：逐段验证「云班账号 → 云班接口 → DSH 问答 → 回发通道」
// 被托盘「检查整个回路」调用；逐行输出 NDJSON 进度，最后一行是总结论。
// 也可以手动跑：node tools/selfcheck.js
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'config', 'bridge.json'), 'utf8'));
const DATA = path.join(ROOT, 'data');
const COOKIE = path.join(DATA, 'session_cookies.json');

const { createSeewo } = require(path.join(ROOT, 'bridge', 'lib', 'seewo'));
const account = require(path.join(ROOT, 'bridge', 'lib', 'account'));
const dsh = require(path.join(ROOT, 'bridge', 'lib', 'dsh'));
const lock = require(path.join(ROOT, 'bridge', 'lib', 'session_lock'));

const STAGES = ['登录态与账号', '云班接口 / 班级绑定', 'DSH 启动与问答', '会话锁', '回发通道'];
const results = [];
let seq = 0;

// 进度同时写一份到文件：托盘的 stdout 重定向文件被子进程占着时读不到，
// 这个文件每次都是「打开-追加-关闭」，任何进程都能随时读。
const PROGRESS = path.join(DATA, 'selfcheck.progress');
try { fs.writeFileSync(PROGRESS, ''); } catch { }

function emit(obj) {
  const line = JSON.stringify(obj) + '\n';
  process.stdout.write(line);
  try { fs.appendFileSync(PROGRESS, line); } catch { }
}
function stage(i, status, detail, extra = {}) {
  emit({ stage: i, total: STAGES.length, name: STAGES[i - 1], status, detail: detail || '', ...extra });
}
const fail = (i, detail) => { results.push({ i, ok: false, detail }); stage(i, 'fail', detail); throw new Error(detail); };
const pass = (i, detail, extra) => { results.push({ i, ok: true, detail }); stage(i, 'ok', detail, extra || {}); };
// 带超时保护：settle 后要清掉定时器，否则事件循环会挂到超时那一刻
const withTimeout = (p, ms, label) => {
  let t;
  const guard = new Promise((_, rej) => {
    t = setTimeout(() => rej(new Error(`${label} 超时（${Math.round(ms / 1000)}s）`)), ms);
  });
  return Promise.race([p, guard]).finally(() => clearTimeout(t));
};

(async () => {
  const t0 = Date.now();
  emit({ start: true, total: STAGES.length, at: new Date().toISOString() });

  // ── 1. 登录态与账号 ──
  try {
    stage(1, 'running', '检查登录态文件与账号身份…');
    if (!fs.existsSync(COOKIE)) fail(1, '缺少登录态：请右键「重新登录」');
    const id = account.readIdentity(COOKIE);
    if (!id.userId) fail(1, '登录态里没有账号信息（cookie 不完整），请重新登录');
    const ageH = (Date.now() - fs.statSync(COOKIE).mtimeMs) / 3600000;
    pass(1, `账号 ${id.userId.slice(0, 10)}…${id.userName ? '（' + id.userName + '）' : ''}，登录态已 ${ageH.toFixed(1)} 小时`);
    seq = 1;
  } catch (e) { emit({ done: true, ok: false, stage: 1, name: STAGES[0], reason: e.message, lines: results, ms: Date.now() - t0 }); process.exit(0); }

  const seewo = createSeewo({ cookieFile: COOKIE });
  let binding = {
    userUid: cfg.云班.userUid || account.readIdentity(COOKIE).userId,
    classUid: cfg.云班.classUid || '',
    schoolUid: cfg.云班.schoolUid || '',
  };

  // ── 2. 云班接口 / 班级绑定 ──
  let dialogs = [];
  try {
    stage(2, 'running', '请求云班会话列表…');
    if (!binding.classUid) {
      stage(2, 'running', '配置里没有班级，正在自动发现…');
      const d = await withTimeout(account.discoverClasses({ seewo, userId: binding.userUid }), 20000, '班级发现');
      if (!d.classes.length) fail(2, '没能发现任何班级（账号未加入班级，或登录态失效）');
      binding.classUid = d.classes[0].classUid;
      binding.schoolUid = d.classes[0].schoolUid || binding.schoolUid;
    }
    dialogs = await withTimeout(seewo.listDialogs({ classUid: binding.classUid, userUid: binding.userUid }), 20000, '会话列表');
    const n = dialogs.length;
    pass(2, n ? `接口正常，${n} 个会话` : '接口正常，暂时没有会话（还没人给这个账号留言）', { dialogs: n });
    seq = 2;
  } catch (e) {
    const msg = e.code === 'AUTH' ? '登录态已失效（接口返回未授权）→ 请右键「重新登录」' : e.message;
    fail(2, msg);
    emit({ done: true, ok: false, stage: 2, name: STAGES[1], reason: msg, lines: results, ms: Date.now() - t0 });
    process.exit(0);
  }

  // ── 3. DSH 启动与问答（真发一句） ──
  let sid = null;
  try {
    stage(3, 'running', '检查 DSH 安装…');
    const inst = dsh.findInstall();
    if (!inst) fail(3, '未找到 DeepSeek Harness（可设环境变量 DSH_APP_DIR）');
    stage(3, 'running', '正在让 DSH 回答一句测试问题（约 5~15 秒）…');
    const r = await withTimeout(
      dsh.askOnce({
        prompt: '这是一次连通性自检，请只回两个字：正常',
        cwd: (cfg.DSH.workspace || 'D:/云班'),
        profile: cfg.DSH.profile || 'yunban',
        timeoutMs: Math.min(cfg.DSH.timeoutMs || 90000, 60000),
      }),
      75000, 'DSH 问答'
    );
    sid = r.sessionId;
    const text = (r.text || '').trim();
    if (!text) fail(3, 'DSH 有响应但没有正文（可能是凭证失效或人格配置异常）');
    pass(3, `DSH 正常作答：${text.slice(0, 18).replace(/\n/g, ' ')}（${r.usage ? r.usage.totalTokens + ' tokens' : '已返回'}）`);
    seq = 3;
  } catch (e) {
    const msg = /no credential|鉴权失败|未授权/i.test(e.message) ? 'DSH 没有可用凭证（模型 API Key 失效）' : e.message;
    fail(3, msg);
    emit({ done: true, ok: false, stage: 3, name: STAGES[2], reason: msg, lines: results, ms: Date.now() - t0 });
    process.exit(0);
  }

  // ── 4. 会话锁（并发保护是否可用） ──
  try {
    stage(4, 'running', '检查会话锁目录…');
    if (!sid) fail(4, '上一阶段没拿到会话 id，无法校验');
    const t = Date.now();
    const l = await withTimeout(lock.acquire(sid, { timeoutMs: 5000 }), 8000, '会话锁');
    l.release();
    const still = fs.existsSync(lock.lockFile(sid));
    if (still) fail(4, '会话锁释放失败（锁文件残留）');
    pass(4, `可正常加锁/释放（${Date.now() - t}ms）`);
    seq = 4;
  } catch (e) {
    fail(4, e.message);
    emit({ done: true, ok: false, stage: 4, name: STAGES[3], reason: e.message, lines: results, ms: Date.now() - t0 });
    process.exit(0);
  }

  // ── 5. 回发通道 ──
  try {
    stage(5, 'running', '校验回发参数与鉴权…');
    if (!binding.schoolUid) fail(5, '缺少 schoolUid（学校标识），无法回发');
    if (!binding.classUid) fail(5, '缺少 classUid（班级标识），无法回发');
    if (!binding.userUid) fail(5, '缺少 userUid（发送者），无法回发');
    if (!cfg.云班.senderType) fail(5, '缺少 senderType（家长/老师身份），无法回发');

    // 用读接口验鉴权（发送接口同一套鉴权），避免真发一条打扰对方
    if (dialogs.length) {
      const peer = dialogs[0].userUid || dialogs[0].uid;
      await withTimeout(seewo.listNotes({ selfUid: binding.userUid, peerUid: peer, pageSize: 1 }), 15000, '留言读取');
      pass(5, `参数齐全、鉴权有效（未实际发送，避免打扰对方；会话对象 ${(dialogs[0].userName || peer)}）`);
    } else {
      pass(5, '参数齐全、鉴权有效（当前没有会话对象，未实际发送）');
    }
    seq = 5;
  } catch (e) {
    fail(5, e.message);
    emit({ done: true, ok: false, stage: 5, name: STAGES[4], reason: e.message, lines: results, ms: Date.now() - t0 });
    process.exit(0);
  }

  // ── 附加提示：同账号是否还有别的客户端在跑（同账号才会互相顶掉） ──
  const notes = [];
  try {
    const peersLib = require(path.join(ROOT, 'bridge', 'lib', 'peers'));
    const peers = await peersLib.detectPeers((cfg.云班 && cfg.云班.同账号客户端) || []);
    const report = peersLib.accountReport(binding.userUid, (cfg.云班 && cfg.云班.其它客户端登录态) || []);
    const same = report.filter(r => r.ok && r.same);
    const diff = report.filter(r => r.ok && !r.same);
    const shared = ((cfg.云班 && cfg.云班.登录态共享) || []).length;

    if (same.length) {
      notes.push(`另一个客户端用的是同一个云班账号（${same.map(r => r.uid.slice(0, 10) + '…').join('、')}）`
        + (shared ? '，已开启登录态共享' : '，两边各自登录会互相顶掉'));
    } else if (diff.length) {
      notes.push(`另一个客户端使用不同账号（${diff.map(r => r.uid.slice(0, 10) + '…').join('、')}），登录态互不影响`);
    } else if (peers.length) {
      notes.push(`检测到其它云班客户端在运行（${[...new Set(peers.map(p => p.label || p.name))].join('、')}），登录态各用各的`);
    }
  } catch { }

  emit({ done: true, ok: true, lines: results, ms: Date.now() - t0, sessionId: sid, dialogs: dialogs.length, notes });
  process.exit(0);
})();
