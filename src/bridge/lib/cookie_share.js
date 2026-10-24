// 登录态共享：让同一账号的多个客户端用同一份 token，避免各自登录互相顶掉
// 合并而不是覆盖：保留目标文件里原有的其它键（比如 QQ云班互联 里的 userUid）
const fs = require('fs');
const path = require('path');

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

/**
 * 把源登录态合并进目标文件
 * @returns {{file:string, ok:boolean, merged:number, err?:string}}
 */
function mergeInto(srcJar, targetFile, { backup = true, log } = {}) {
  try {
    const dir = path.dirname(targetFile);
    fs.mkdirSync(dir, { recursive: true });

    const target = readJson(targetFile) || {};
    if (backup && fs.existsSync(targetFile)) {
      const bak = targetFile + '.bak-' + new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
      try { fs.copyFileSync(targetFile, bak); log && log.info(`已备份目标登录态：${path.basename(bak)}`); } catch { }
    }

    let merged = 0;
    for (const [domain, kv] of Object.entries(srcJar)) {
      target[domain] = target[domain] || {};
      for (const [k, v] of Object.entries(kv)) {
        if (target[domain][k] !== v) merged++;
        target[domain][k] = v;
      }
    }

    // 有的客户端读的是 userUid 而不是 userId（QQ云班互联 就是），
    // 只同步 token 不同步 uid，对方会拿旧 uid 配新 token，照样 40105。
    const idDom = target['id.seewo.com'] || {};
    const uid = idDom.userId || (srcJar['id.seewo.com'] || {}).userId;
    if (uid && idDom.userUid !== uid) { idDom.userUid = uid; merged++; }
    // 学校标识也一并带上（对方可能从登录态取）
    const orgUid = (srcJar['m-campus.seewo.com'] || {})['x-org-uid'];
    if (orgUid && idDom.schoolUid !== orgUid) { idDom.schoolUid = orgUid; merged++; }

    fs.writeFileSync(targetFile, JSON.stringify(target, null, 2), 'utf8');
    return { file: targetFile, ok: true, merged, uid: uid || null };
  } catch (e) {
    return { file: targetFile, ok: false, merged: 0, err: e.message };
  }
}

/** 按配置把登录态同步到所有目标 */
function syncAll(srcJar, targets, { log } = {}) {
  const out = [];
  for (const t of (targets || [])) {
    if (!t || typeof t !== 'string') continue;
    const r = mergeInto(srcJar, t, { log });
    if (r.ok) log && log.info(`登录态已同步到 ${t}（更新 ${r.merged} 个字段）`);
    else log && log.warn(`登录态同步失败 ${t}：${r.err}`);
    out.push(r);
  }
  return out;
}

module.exports = { mergeInto, syncAll };
