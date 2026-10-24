// 同账号客户端检测：机器上是否还跑着别的云班客户端（比如 QQ云班互联）
// 两个客户端各自登录同一账号时，容易有一方的 token 被顶掉，报 40105/9999。
const { execFile } = require('child_process');

const DEFAULT_NAMES = ['QQ云班互联'];

/**
 * 检测正在运行的同类客户端
 * @param {string[]} names 进程命令行里出现的关键词
 * @returns {Promise<Array<{pid:number,name:string,cmd:string}>>}
 */
function detectPeers(names = DEFAULT_NAMES, timeoutMs = 8000) {
  const kw = (names && names.length ? names : []).filter(Boolean);
  if (!kw.length) return Promise.resolve([]);

  const cond = kw.map(k => `$_.CommandLine -like '*${k.replace(/'/g, "''")}*'`).join(' -or ');
  // 必须先把 PowerShell 的输出编码改成 UTF-8，否则中文路径（QQ云班互联）会变成乱码，
  // Node 侧按 utf8 解码就成了问号，关键词也就匹配不上。
  const script = `[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; `
    + `$OutputEncoding=[System.Text.Encoding]::UTF8; `
    + `Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne ${process.pid} -and $_.CommandLine -and (${cond}) } `
    + `| Select-Object ProcessId,Name,CommandLine | ConvertTo-Json -Compress`;

  return new Promise(resolve => {
    execFile('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
      { windowsHide: true, timeout: timeoutMs, maxBuffer: 1 << 20 },
      (err, stdout) => {
        if (err || !stdout || !stdout.trim()) return resolve([]);
        try {
          const v = JSON.parse(stdout);
          const arr = Array.isArray(v) ? v : [v];
          resolve(arr
            // 把「我自己这次查询用的 powershell」过滤掉：它的命令行里也含这些关键词
            .filter(x => x.CommandLine && !/Get-CimInstance\s+Win32_Process/i.test(x.CommandLine))
            .map(x => {
              const cmd = String(x.CommandLine || '');
              const label = kw.find(k => cmd.includes(k)) || x.Name;
              return { pid: x.ProcessId, name: x.Name, label, cmd };
            }));
        } catch { resolve([]); }
      });
  });
}

module.exports = { detectPeers, DEFAULT_NAMES, readAccountOf, accountReport };

/**
 * 读一份登录态里的账号与 token（不联网）
 * @returns {{uid:string, token:string, mtime:number}|null}
 */
function readAccountOf(jarFile) {
  try {
    const j = JSON.parse(require('fs').readFileSync(jarFile, 'utf8'));
    const id = j['id.seewo.com'] || {};
    const uid = String(id.userId || id.userUid || '');
    const token = String((j['m-campus.seewo.com'] || {})['x-auth-token'] || '');
    const mtime = require('fs').statSync(jarFile).mtimeMs;
    return { uid, token, mtime };
  } catch { return null; }
}

/**
 * 对比「我」的账号与其它客户端的账号
 * @param {string} myUid 当前桥接器绑定的账号
 * @param {string[]} jarFiles 其它客户端的登录态文件
 */
function accountReport(myUid, jarFiles = []) {
  const out = [];
  for (const f of jarFiles) {
    if (!f) continue;
    const a = readAccountOf(f);
    if (!a) { out.push({ file: f, ok: false }); continue; }
    out.push({
      file: f,
      ok: true,
      uid: a.uid,
      token: a.token,
      // 只有 uid 相同才算"同账号"，才可能互相顶掉
      same: !!myUid && a.uid === myUid,
    });
  }
  return out;
}
