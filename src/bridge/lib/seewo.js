// 云班「亲情留言」客户端（生产版）
// 协议：POST https://m-campus.seewo.com/class/apis.json?action=<ACTION>
//       body { action, params }；返回 data 可能被包成 "scData:<base64>"
const fs = require('fs');
const https = require('https');

// 可用 SEEWO_BASE 覆盖（测试时指向本地假服务器）
const BASE = process.env.SEEWO_BASE || 'https://m-campus.seewo.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

class AuthError extends Error {
  constructor(msg) { super(msg); this.code = 'AUTH'; }
}

// 业务码/文案 → 判定为登录态失效
const AUTH_CODES = new Set([61009, 40100, 40101, 40102, 40103, 40104, 40105, 40106, 40107, 40108, 40109, 40110]);
const AUTH_TEXT = /鉴权失败|未授权|登录态|请先登录|重新登录|token[^。]*(失效|过期|无效)|会话[^。]*(失效|过期)/i;
function isAuthFailure(json) {
  if (!json) return false;
  if (AUTH_CODES.has(json.statusCode)) return true;
  return AUTH_TEXT.test(String(json.message || ''));
}

function decodePayload(data) {
  if (typeof data === 'string' && data.startsWith('scData:')) {
    try { return JSON.parse(Buffer.from(data.slice(7), 'base64').toString('utf8')); } catch { return data; }
  }
  return data;
}

function createSeewo({ cookieFile, referer = '/class/message', timeoutMs = 15000, log } = {}) {
  function cookieHeader(host) {
    let jar = {};
    try { jar = JSON.parse(fs.readFileSync(cookieFile, 'utf8')); } catch {
      throw new AuthError(`无法读取登录态文件：${cookieFile}（请先执行 --login）`);
    }
    const parts = [];
    for (const [domain, kv] of Object.entries(jar)) {
      const d = domain.replace(/^\./, '');
      if (host === d || host.endsWith('.' + d)) {
        for (const [k, v] of Object.entries(kv)) parts.push(`${k}=${v}`);
      }
    }
    return parts.join('; ');
  }

  function call(action, params = {}) {
    const body = JSON.stringify({ action, params });
    const u = new URL('/class/apis.json?action=' + encodeURIComponent(action), BASE);
    return new Promise((resolve, reject) => {
      let cookie;
      try { cookie = cookieHeader(u.hostname); } catch (e) { return reject(e); }
      // 按协议选 http/https（测试用的假服务器是 http）
      const client = u.protocol === 'http:' ? require('http') : https;
      const req = client.request(u, {
        method: 'POST',
        headers: {
          'User-Agent': UA,
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body),
          'Origin': BASE,
          'Referer': BASE + referer,
          'Cookie': cookie,
        },
        rejectUnauthorized: false,
        timeout: timeoutMs,
      }, res => {
        const chunks = [];
        res.on('data', c => chunks.push(c));
        res.on('end', () => {
          let json = null;
          try { json = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { }
          if (!json) return reject(new Error(`[${action}] 返回非 JSON（HTTP ${res.statusCode}）`));
          if (json.statusCode === 200) { json.data = decodePayload(json.data); return resolve(json); }
          // 登录态失效有多种表现：HTTP 401、业务码 401xx / 61009、以及"鉴权失败/当前用户未授权"这类文案。
          // 账号被重新注册后，接口就是回 40106「当前用户未授权」——必须当成 AUTH，
          // 否则会被当作普通错误静默重试，既不提示重新登录也不会触发重新绑定。
          if (res.statusCode === 401 || isAuthFailure(json)) {
            return reject(new AuthError(`[${action}] ${json.message || '登录态失效'}（code=${json.statusCode}）`));
          }
          const e = new Error(`[${action}] ${json.message || '请求失败'}`);
          e.status = res.statusCode;
          e.raw = json;
          reject(e);
        });
      });
      req.on('timeout', () => req.destroy(new Error(`[${action}] 请求超时`)));
      req.on('error', reject);
      req.end(body);
    });
  }

  /** 会话列表：教师端 V2 优先，家长端回落 V1 */
  async function listDialogs({ classUid, userUid }) {
    try {
      const d2 = await call('GET_KIDNOTE_V2_NOTE_DIALOGS', { unitId: classUid, userUid, page: 1, pageSize: 50 });
      const list = (d2.data && d2.data.result) || [];
      if (list.length) return list.map(x => ({ ...x, classUid }));
    } catch (e) {
      if (e.code === 'AUTH') throw e;
      if (log) log.debug(`V2 会话列表不可用，回落 V1：${e.message}`);
    }
    const d1 = await call('GET_KIDNOTE_V1_NOTE_DIALOGS', { classUid, userUid });
    return (d1.data || []).map(x => ({ ...x, classUid }));
  }

  /** 某个会话的留言列表 */
  async function listNotes({ selfUid, peerUid, start = 1, pageSize = 20 }) {
    const r = await call('GET_KIDNOTE_V1_BYPARENTUID_BYCHILDUID_NOTES', { page: 1, pageSize, start, parentUid: selfUid, childUid: peerUid });
    return (r.data && r.data.result) || [];
  }

  /** 发送留言 */
  function sendNote({ schoolUid, classUid, senderUid, receiverUid, senderType = 'parent', type = 1, content }) {
    return call('POST_KIDNOTE_V1_NOTE', { schoolUid, classUid, senderUid, receiverUid, senderType, type, content });
  }

  return { call, listDialogs, listNotes, sendNote, AuthError };
}

module.exports = { createSeewo, AuthError, decodePayload };
