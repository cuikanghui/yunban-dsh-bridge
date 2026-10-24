// 简单的 JSON 持久化：原子写入（tmp + rename），避免断电/崩溃把文件写坏
const fs = require('fs');
const path = require('path');

function readJson(file, fallback = {}) {
  try {
    const raw = fs.readFileSync(file, 'utf8');
    return raw.trim() ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

function writeJson(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

/** 带自动落盘的键值表 */
function createStore(file) {
  let data = readJson(file, {});
  return {
    get all() { return data; },
    get(k, d) { return k in data ? data[k] : d; },
    set(k, v) { data[k] = v; writeJson(file, data); },
    del(k) { delete data[k]; writeJson(file, data); },
    save() { writeJson(file, data); },
    reload() { data = readJson(file, {}); return data; },
  };
}

module.exports = { readJson, writeJson, createStore };
