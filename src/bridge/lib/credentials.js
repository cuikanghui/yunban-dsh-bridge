// 从 DSH 的凭证文件里取出 API key，供 headless 子进程使用
// 背景：新版 DSH 的 headless 模式不再自动读取桌面端存的凭证，
//       运行时报 MISSING_CREDENTIAL。这里把 key 注入到子进程环境变量即可。
// 文件：~/.dsh/.credentials.yaml，结构里 refs: 段是 "KEY: 明文值"
const fs = require('fs');
const os = require('os');
const path = require('path');

const CRED_FILE = path.join(os.homedir(), '.dsh', '.credentials.yaml');
const KEY_RE = /^[A-Za-z0-9_\-.]{16,300}$/;         // 形如 sk-xxxx，排除带空格/引号的值

/** 读取 refs 段，返回 { KEY: value } */
function readRefs(file = CRED_FILE) {
  const out = {};
  if (!fs.existsSync(file)) return out;
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  let inRefs = false;
  for (const line of lines) {
    if (!inRefs) {
      if (/^refs:\s*$/.test(line)) inRefs = true;
      continue;
    }
    if (/^\S/.test(line)) break;                     // 离开 refs 段
    const m = line.match(/^\s+([A-Za-z0-9_]+):\s*(.+?)\s*$/);
    if (m && KEY_RE.test(m[2])) out[m[1]] = m[2];
  }
  return out;
}

/**
 * 把凭证注入到给定的 env 对象（已存在的环境变量优先，不覆盖）
 * @returns {string[]} 实际注入的变量名
 */
function injectInto(env = process.env, names = ['DEEPSEEK_API_KEY', 'ABC_API_KEY']) {
  const refs = readRefs();
  const injected = [];
  for (const n of names) {
    if (!env[n] && refs[n]) { env[n] = refs[n]; injected.push(n); }
  }
  return injected;
}

module.exports = { readRefs, injectInto, CRED_FILE };
