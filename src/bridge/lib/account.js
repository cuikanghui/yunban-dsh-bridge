// 账号身份与本班发现
// 背景：旧版本把 classUid / userUid 写死在 config 里，一旦家长重新注册账号，
// 这些标识就全部失效（接口报「鉴权失败 / 当前用户未授权」），而程序没有任何自愈路径。
// 这里改为：以 cookie 里的真实账号为准 → 主动发现孩子/班级 → 回写配置。
const fs = require('fs');

function readJson(file, fb = {}) {
  try { const s = fs.readFileSync(file, 'utf8'); return s.trim() ? JSON.parse(s) : fb; } catch { return fb; }
}

/** 从登录态文件里读出当前账号身份（不依赖 config） */
function readIdentity(cookieFile) {
  const jar = readJson(cookieFile, {});
  const id = jar['id.seewo.com'] || {};
  const campus = jar['m-campus.seewo.com'] || {};
  return {
    userId: id.userId || null,
    userName: id.username ? decodeURIComponent(id.username) : null,
    nickname: id.nickname ? decodeURIComponent(id.nickname) : null,
    schoolUid: campus['x-org-uid'] || campus['x-auth-schoolUid'] || null,
    userType: campus['x-auth-userType'] || null,
  };
}

// 从任意层级的对象里挑出可能的字段
const pick = (obj, names) => {
  for (const n of names) {
    if (obj && obj[n] !== undefined && obj[n] !== null && String(obj[n]).trim() !== '') return String(obj[n]);
  }
  return null;
};

function flattenCandidates(data, out = []) {
  if (!data) return out;
  if (Array.isArray(data)) {
    for (const it of data) flattenCandidates(it, out);
    return out;
  }
  if (typeof data === 'object') {
    const classUid = pick(data, ['classUid', 'classId', 'classuid', 'unitId', 'classUidStr']);
    const childUid = pick(data, ['childUid', 'userUid', 'studentUid', 'studentUserUid', 'uid']);
    if (classUid) {
      out.push({
        classUid,
        schoolUid: pick(data, ['schoolUid', 'orgUid', 'schoolId']),
        childUid,
        childName: pick(data, ['childName', 'studentName', 'userName', 'name', 'nickName']),
        className: pick(data, ['className', 'classNickName', 'unitName']),
      });
    }
    for (const v of Object.values(data)) {
      if (v && typeof v === 'object') flattenCandidates(v, out);
    }
  }
  return out;
}

function dedupe(list) {
  const seen = new Map();
  for (const c of list) {
    if (!seen.has(c.classUid)) seen.set(c.classUid, c);
    else {
      const old = seen.get(c.classUid);
      if (!old.childUid && c.childUid) seen.set(c.classUid, { ...old, ...c });
    }
  }
  return [...seen.values()];
}

/**
 * 主动发现当前账号绑定的班级（按成功率依次尝试多个接口）
 * @returns {Promise<{classes:Array, source:string, tried:Array}>}
 */
async function discoverClasses({ seewo, userId, log }) {
  const candidates = [
    ['GET_STUDENT_V1_PARENT_BYPARENTUID_CHILDREN_LIST', { parentUid: userId }],
    ['GET_STUDENT_V1_PARENT_BYPARENTID_CHILDREN_LIST', { parentId: userId }],
    ['GET_CLASSMEMBER_V1_BYUSERUID_CHILDREN', { userUid: userId }],
  ];
  const tried = [];
  for (const [action, params] of candidates) {
    try {
      const r = await seewo.call(action, params);
      const found = dedupe(flattenCandidates(r.data));
      tried.push({ action, ok: true, count: found.length });
      if (log) log.debug(`发现接口 ${action} 返回 ${found.length} 个班级`);
      if (found.length) return { classes: found, source: action, tried };
    } catch (e) {
      tried.push({ action, ok: false, err: e.message });
      if (log) log.debug(`发现接口 ${action} 失败：${e.message}`);
      if (e.code === 'AUTH') return { classes: [], source: action, tried, authFail: true };
    }
  }
  return { classes: [], source: null, tried };
}

module.exports = { readIdentity, discoverClasses, flattenCandidates };
