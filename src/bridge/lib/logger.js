// 中文分级日志：同时输出到控制台与按天滚动的文件
const fs = require('fs');
const path = require('path');

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };
const LABEL = { debug: '调试', info: '信息', warn: '警告', error: '错误' };

function pad(n) { return String(n).padStart(2, '0'); }
function dateStr(d = new Date()) { return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; }
function timeStr(d = new Date()) { return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`; }

function createLogger({ dir, level = 'info', keepDays = 14, toConsole = true } = {}) {
  const min = LEVELS[level] || LEVELS.info;
  if (dir) fs.mkdirSync(dir, { recursive: true });
  let currentDay = null;
  let stream = null;

  function rotate() {
    if (!dir) return;
    const d = dateStr();
    if (d === currentDay) return;
    if (stream) { try { stream.end(); } catch { } }
    currentDay = d;
    stream = fs.createWriteStream(path.join(dir, `${d}.log`), { flags: 'a' });
    cleanup();
  }

  function cleanup() {
    try {
      const files = fs.readdirSync(dir).filter(f => /^\d{4}-\d{2}-\d{2}\.log$/.test(f)).sort();
      while (files.length > keepDays) fs.unlinkSync(path.join(dir, files.shift()));
    } catch { }
  }

  function write(lv, args) {
    if (LEVELS[lv] < min) return;
    rotate();
    const msg = args.map(a => (typeof a === 'string' ? a : a instanceof Error ? a.message : JSON.stringify(a))).join(' ');
    const line = `[${dateStr()} ${timeStr()}] [${LABEL[lv]}] ${msg}`;
    if (toConsole) (lv === 'error' ? console.error : console.log)(line);
    if (stream) stream.write(line + '\n');
  }

  return {
    debug: (...a) => write('debug', a),
    info: (...a) => write('info', a),
    warn: (...a) => write('warn', a),
    error: (...a) => write('error', a),
    close: () => { if (stream) { try { stream.end(); } catch { } } },
  };
}

module.exports = { createLogger };
