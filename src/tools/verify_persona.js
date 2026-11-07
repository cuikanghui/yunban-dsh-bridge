// 核验 DSH 实际加载的 personaPrefix（给 人格设置.ps1 调用）
// 用法：node verify_persona.js [profileName]
// 输出：单行 JSON  {"ok":true,"persona":"..."} 或 {"ok":false,"error":"..."}
//
// 为什么不用 PowerShell 直接跑：Electron 会把 --dump-config 的输出直接写到控制台，
// PowerShell 的管道/重定向抓不全；Node 的 execFile 能稳定拿到完整 stdout。
const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');

const profile = process.argv[2] || 'yunban';
// --out=<文件>：把结果写文件（调用方读文件，避免依赖子进程 stdout 捕获）
const outArg = process.argv.slice(3).find(a => a.startsWith('--out='));
const outFile = outArg ? outArg.slice('--out='.length) : null;

const dirs = [
  process.env.DSH_APP_DIR,
  process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'Programs', 'DeepSeek Harness'),
  process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'DeepSeekHarness'),
  'C:\\Program Files\\DeepSeek Harness',
  'D:\\DeepSeekHarness',
].filter(Boolean);

function findInstall() {
  for (const d of dirs) {
    const exe = path.join(d, 'app', 'DeepSeek Harness.exe');
    if (fs.existsSync(exe)) return { dir: d, exe };
  }
  return null;
}

function parsePersona(text) {
  const lines = String(text).split(/\r?\n/);
  const re = /^(\s*)personaPrefix:[ \t]*\|[ \t]*$/;
  const idx = lines.findIndex(l => re.test(l));
  if (idx < 0) return null;
  const bodyIndent = (lines[idx].match(re) || [])[1].length + 2;
  const body = [];
  for (let i = idx + 1; i < lines.length; i++) {
    const l = lines[i];
    if (l.trim() === '') { body.push(''); continue; }
    const ind = (l.match(/^(\s*)/) || ['', ''])[1].length;
    if (ind < bodyIndent) break;
    body.push(l.slice(bodyIndent));
  }
  while (body.length && body[body.length - 1].trim() === '') body.pop();
  return body.join('\n');
}

function out(o) {
  const line = JSON.stringify(o) + '\n';
  try { process.stdout.write(line); } catch { }
  if (outFile) { try { fs.writeFileSync(outFile, line, 'utf8'); } catch { } }
}

const inst = findInstall();
if (!inst) { out({ ok: false, error: '未找到 DeepSeek Harness 安装' }); process.exit(0); }

const cli = path.join(inst.dir, 'app', 'resources', 'app.asar', 'dsh', 'node_modules',
  '@deepseek-ai', 'dsh-desktop-host', 'lib', 'cli.js');

execFile(inst.exe, ['--expose-internals', cli, '--profile', profile, '--dump-config'], {
  cwd: process.env.USERPROFILE || 'C:\\',
  env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
  windowsHide: true,
  timeout: 60000,
  maxBuffer: 16 << 20,
}, (err, stdout) => {
  if (err && !stdout) { out({ ok: false, error: 'DSH 没返回配置：' + err.message }); return; }
  const persona = parsePersona(stdout);
  if (persona === null) { out({ ok: false, error: 'DSH 的合成配置里没有 personaPrefix 段' }); return; }
  out({ ok: true, persona });
});
