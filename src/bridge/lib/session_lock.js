// 跨进程会话锁
// 为什么需要：main.js 里的 withPeerLock 只在本进程内有效。
// 如果同时跑了两份桥接（开发目录 / 安装目录各一份），或者桥接与其它脚本共用同一会话，
// 两边都会去驱动同一个 DSH session，DSH 侧会报
//   dsh: session "..." is already owned by an active write handle
// 这里用「原子创建锁文件」做跨进程互斥，并且能自动回收死进程留下的锁。
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

// 放在 LOCALAPPDATA 下：所有副本共享同一处，不会各锁各的
const ROOT = path.join(process.env.LOCALAPPDATA || os.tmpdir(), 'YunbanBridge', 'session-locks');
const MAX_HOLD_MS = 15 * 60 * 1000;   // 超过 15 分钟视为异常残留

function lockFile(key) {
  const h = crypto.createHash('sha1').update(String(key)).digest('hex').slice(0, 16);
  return path.join(ROOT, h + '.lock');
}

function isAlive(pid) {
  if (!pid) return false;
  try { process.kill(pid, 0); return true; } catch { return false; }
}

function readLock(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

/**
 * 获取会话锁
 * @returns {Promise<{release: Function, waited: number, reclaimed: boolean}>}
 */
async function acquire(key, { timeoutMs = 30000, pollMs = 250, log } = {}) {
  fs.mkdirSync(ROOT, { recursive: true });
  const file = lockFile(key);
  const token = process.pid + '-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
  const started = Date.now();
  let reclaimed = false;

  for (;;) {
    try {
      // 'wx' = 文件已存在则失败，这是原子操作，能当互斥量用
      const fd = fs.openSync(file, 'wx');
      fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, token, at: Date.now(), key: String(key) }));
      fs.closeSync(fd);

      let released = false;
      const release = () => {
        if (released) return;
        released = true;
        try {
          const cur = readLock(file);
          // 只删自己的锁，避免把别人后来抢到的锁删掉
          if (cur && cur.token === token) fs.unlinkSync(file);
        } catch { }
      };
      return { release, waited: Date.now() - started, reclaimed };
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;

      // 有人占着 → 判断是不是死进程 / 超期残留
      const cur = readLock(file);
      const age = cur ? Date.now() - (cur.at || 0) : MAX_HOLD_MS + 1;
      const dead = cur && cur.pid && !isAlive(cur.pid);
      if (!cur || dead || age > MAX_HOLD_MS) {
        if (log && (dead || !cur)) {
          log.warn(`回收失效的会话锁（pid=${cur ? cur.pid : '未知'}，${dead ? '进程已退出' : '锁文件损坏'}）`);
        }
        reclaimed = true;
        try { fs.unlinkSync(file); } catch { }
        continue;      // 立刻重试抢锁
      }

      if (Date.now() - started > timeoutMs) {
        const e2 = new Error(`等待会话锁超时（${Math.round(timeoutMs / 1000)} 秒），会话正被 pid=${cur && cur.pid} 占用`);
        e2.code = 'BUSY';
        throw e2;
      }
      await new Promise(r => setTimeout(r, pollMs));
    }
  }
}

module.exports = { acquire, lockFile, ROOT };
