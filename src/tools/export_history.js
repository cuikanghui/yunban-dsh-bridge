// 导出云班 ↔ AI 的对话记录为可读 Markdown
// 数据来源：~/.dsh/sessions/<cwd编码>/<sessionId>/session.v4.jsonl.zstd
//   这是「多帧拼接的 zstd」，必须按帧切开逐个解压（单次解压只能拿到第一帧）
// 用法：
//   node tools/export_history.js                导出全部到 exports/
//   node tools/export_history.js --out D:\某目录
//   node tools/export_history.js --session a8ca78d5  只导一个会话
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '..');
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, 'config', 'bridge.json'), 'utf8'));

// Windows 路径 → DSH 会话目录名：D:\云班 → --D-~4E91~73ED--
function encodePath(p) {
  let out = '--';
  for (const ch of p) {
    if (ch === ':') continue;
    if (ch === '\\' || ch === '/') { out += '-'; continue; }
    const c = ch.codePointAt(0);
    out += c < 128 ? ch : '~' + c.toString(16).toUpperCase().padStart(4, '0');
  }
  return out + '--';
}

// 多帧 zstd：按 magic number 切帧
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
function readFrames(file) {
  const buf = fs.readFileSync(file);
  const offs = [];
  let i = 0;
  while ((i = buf.indexOf(MAGIC, i)) >= 0) { offs.push(i); i++; }
  if (!offs.length) return '';
  let text = '';
  for (let k = 0; k < offs.length; k++) {
    const end = k + 1 < offs.length ? offs[k + 1] : buf.length;
    try { text += zlib.zstdDecompressSync(buf.subarray(offs[k], end)).toString('utf8'); } catch { }
  }
  return text;
}

function parseSession(file) {
  const text = readFrames(file);
  const recs = [];
  for (const line of text.split('\n')) {
    const s = line.trim();
    if (!s) continue;
    try { recs.push(JSON.parse(s)); } catch { }
  }
  const head = recs.find(r => r.type === 'session');
  const msgs = [];
  for (const r of recs) {
    if (r.type === 'user/message') {
      const t = (r.data?.content || []).filter(c => c.type === 'text').map(c => c.text).join('\n').trim();
      // 跳过 DSH 注入的运行时上下文（不是用户说的话）
      if (!t || t.startsWith('Current runtime context')) continue;
      msgs.push({ role: 'user', time: r.time, text: t });
    } else if (r.type === 'assistant/message') {
      const t = (r.data?.message?.content || []).filter(c => c.type === 'text').map(c => c.text).join('\n').trim();
      if (!t) continue;
      msgs.push({ role: 'assistant', time: r.time, text: t });
    }
  }
  msgs.sort((a, b) => a.time - b.time);
  return { id: head?.id || path.basename(path.dirname(file)), cwd: head?.cwd, createdAt: head?.createdAt, msgs };
}

const argv = process.argv.slice(2);
const val = k => { const a = argv.find(x => x.startsWith(k + '=')); return a ? a.slice(k.length + 1) : undefined; };
const outDir = val('--out') || path.join(ROOT, 'exports');
const only = val('--session');

const sessionsRoot = path.join(os.homedir(), '.dsh', 'sessions', encodePath(cfg.DSH.workspace || 'D:\\云班'));
if (!fs.existsSync(sessionsRoot)) {
  console.error('找不到会话目录：' + sessionsRoot);
  process.exit(1);
}

const dirs = fs.readdirSync(sessionsRoot).filter(d => d.startsWith('session-'));
const parsed = [];
for (const d of dirs) {
  if (only && !d.includes(only)) continue;
  const f = path.join(sessionsRoot, d, 'session.v4.jsonl.zstd');
  if (!fs.existsSync(f)) continue;
  const s = parseSession(f);
  s.file = f;
  s.size = fs.statSync(f).size;
  parsed.push(s);
}
parsed.sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));

fs.mkdirSync(outDir, { recursive: true });
const stamp = new Date().toISOString().slice(0, 10);
const outFile = path.join(outDir, `对话记录-${stamp}.md`);

const fmt = t => new Date(t).toLocaleString('zh-CN', { hour12: false });
const lines = [];
lines.push(`# 云班 ↔ AI 对话记录`);
lines.push('');
lines.push(`- 导出时间：${new Date().toLocaleString('zh-CN', { hour12: false })}`);
lines.push(`- 来源目录：\`${sessionsRoot}\``);
lines.push(`- 会话数：${parsed.length}，消息总数：${parsed.reduce((n, s) => n + s.msgs.length, 0)}`);
lines.push('');

let total = 0;
for (const s of parsed) {
  if (!s.msgs.length) continue;
  lines.push(`---`);
  lines.push('');
  lines.push(`## 会话 ${s.id.replace('session-', '')}`);
  lines.push('');
  lines.push(`- 开始时间：${s.createdAt ? fmt(s.createdAt) : '未知'}`);
  lines.push(`- 消息数：${s.msgs.length}`);
  lines.push('');
  for (const m of s.msgs) {
    total++;
    const who = m.role === 'user' ? '**云班用户**' : '**AI**';
    lines.push(`${who} · ${fmt(m.time)}`);
    lines.push('');
    lines.push(m.text.split('\n').map(l => (l.trim() ? l : '')).join('\n'));
    lines.push('');
  }
}

if (!total) {
  console.log('这些会话里没有可导出的对话（可能都是空壳会话）。');
}

fs.writeFileSync(outFile, lines.join('\n'), 'utf8');
console.log(`已导出 ${total} 条消息 / ${parsed.length} 个会话`);
console.log(`文件：${outFile}`);
console.log(`大小：${(fs.statSync(outFile).size / 1024).toFixed(1)} KB`);
