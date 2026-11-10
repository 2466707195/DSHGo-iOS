// 验证 iOS 端 DSHTransport 实现的协议是否真的能跑通。
// 用法: node probe.mjs [baseURL]
const base = (process.argv[2] || 'http://127.0.0.1:3081').replace(/\/$/, '');

const UA_APP = 'DSHGo/1.0 (iOS)';
const UA_BROWSER =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
  + '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 DshRemote/1.0';

const log = (...a) => console.log(...a);

async function getJSON(path, ua) {
  const res = await fetch(base + path, { headers: { Accept: 'application/json', 'User-Agent': ua } });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* ignore */ }
  return { status: res.status, json, text, headers: res.headers };
}

async function main() {
  log('== 1. 探测 ===============');
  const status = await getJSON('/__dshgo__/auth/status', UA_BROWSER);
  log('auth/status', status.status, status.text.slice(0, 120));
  const info = await getJSON('/__dshgo__/info', UA_BROWSER);
  log('info', info.status, JSON.stringify({
    name: info.json?.name, version: info.json?.version, listening: info.json?.listening,
    port: info.json?.port, upstreamPort: info.json?.upstreamPort,
    addresses: info.json?.addresses, tailscale: info.json?.tailscale,
  }));

  log('\n== 2. 握手（手写跳转、逐跳收 cookie）===============');
  // 与 Android Handshake.java 一致：不自动跟重定向，手写跳转、逐跳收 Set-Cookie，
  // 且**每一跳都带上已收到的 cookie** —— 不带就会 303 → / → 303 无限循环
  // （token 换 cookie 后上游回 303，location 是相对路径 /）。
  const cookieJar = new Map();
  const MAX_HOPS = 6;
  let url = base + '/';
  let hsStatus = 0;
  let hsBody = '';
  for (let hop = 0; hop < MAX_HOPS; hop += 1) {
    const header = { Accept: 'text/html,application/xhtml+xml', 'User-Agent': UA_BROWSER };
    if (cookieJar.size > 0) {
      header.Cookie = [...cookieJar].map(([k, v]) => `${k}=${v}`).join('; ');
    }
    const res = await fetch(url, { headers: header, redirect: 'manual' });
    hsStatus = res.status;
    for (const c of res.headers.getSetCookie?.() ?? []) {
      const [pair] = c.split(';');
      const i = pair.indexOf('=');
      if (i > 0) cookieJar.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
    }
    if (res.status >= 300 && res.status < 400) {
      const location = res.headers.get('location');
      if (!location) { log('重定向缺少 Location'); break; }
      url = new URL(location, url).toString();
      continue;
    }
    hsBody = (await res.text()).slice(0, 200);
    break;
  }
  log('握手 status', hsStatus, '| 最终 url', url, '| cookie:', [...cookieJar.keys()].join(', ') || '(none)');
  log('首屏片段:', hsBody.replace(/\s+/g, ' ').slice(0, 120));
  const authCount = [...cookieJar.keys()].filter((k) => k.startsWith('dsh-auth')).length;
  log('dsh-auth 条数:', authCount);
  const cookieHeader = [...cookieJar].map(([k, v]) => `${k}=${v}`).join('; ');

  log('\n== 3. 一元 RPC session/list ===============');
  const rpc = await fetch(base + '/api/session/list', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json',
      'User-Agent': UA_APP,
      Cookie: cookieHeader,
    },
    body: JSON.stringify({
      type: 'client-request',
      rpcId: 'probe-1',
      method: 'session/list',
      payload: { args: { _request: {} } },
    }),
  });
  const rpcText = await rpc.text();
  log('status', rpc.status);
  let value = null;
  try {
    const env = JSON.parse(rpcText);
    const result = env.result;
    log('result.ok =', result?.ok);
    value = result?.value;
    const items = value?.items ?? [];
    log('items:', items.length);
    for (const it of items.slice(0, 5)) {
      log('  -', it.sessionId, '| running =', it.running,
        '| title =', it.projections?.values?.title ?? '(空)',
        '| updatedAt =', it.updatedAt);
    }
  } catch {
    log('原始返回:', rpcText.slice(0, 400));
  }

  log('\n== 4. 事件流 /api/remote.mux ===============');
  const wsUrl = base.replace('http://', 'ws://').replace('https://', 'wss://') + '/api/remote.mux';
  const ws = new WebSocket(wsUrl, { headers: { Cookie: cookieHeader, 'User-Agent': UA_APP } });
  let gotReady = false;
  const seen = new Set();

  await new Promise((resolve) => {
    const timer = setTimeout(() => { log('（6 秒超时，主动收尾）'); try { ws.close(); } catch {} resolve(); }, 6000);
    ws.onopen = () => {
      log('ws open，发送 open $events');
      ws.send(JSON.stringify({ type: 'open', streamId: 'probe-1', endpoint: '$events', payload: { args: {} } }));
    };
    ws.onmessage = async (ev) => {
      let frame;
      try { frame = JSON.parse(String(ev.data)); } catch { return; }
      if (frame.type !== 'item') { log('非 item 帧:', JSON.stringify(frame).slice(0, 120)); return; }
      const v = frame.value ?? {};
      if (v.type === 'ready') {
        gotReady = true;
        log('ready: clientId =', v.clientId, '| host =', JSON.stringify(v.host));
      } else if (v.type === 'emit') {
        const key = 'emit:' + v.event;
        if (!seen.has(key)) { seen.add(key); log('emit:', v.event, JSON.stringify(v.args).slice(0, 160)); }
      } else if (v.type === 'waterfall') {
        const key = 'waterfall:' + v.event;
        if (!seen.has(key)) {
          seen.add(key);
          log('waterfall:', v.event, '| eventId =', v.eventId, '| request =', JSON.stringify(v.request).slice(0, 200));
          // 立刻回执 next，避免卡住宿主的链条
          const reply = await fetch(base + '/api/$events/result', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json', Accept: 'application/json',
              'User-Agent': UA_APP, Cookie: cookieHeader,
            },
            body: JSON.stringify({
              type: 'client-request', rpcId: 'probe-reply', method: '$events/result',
              payload: { args: { clientId: v.clientId ?? '', eventId: v.eventId, outcome: { kind: 'next' } } },
            }),
          });
          log('  → 回执 next:', reply.status);
        }
      }
    };
    ws.onerror = (e) => { log('ws error:', e.message ?? e); };
    ws.onclose = (e) => { log('ws closed:', e.code, e.reason || ''); clearTimeout(timer); resolve(); };
  });

  log('\n== 结论 ===============');
  log('探测可用:', info.json?.name === 'dshgo');
  log('握手拿到 dsh-auth cookie:', authCount > 0);
  log('session/list 可用:', Array.isArray(value?.items));
  log('事件流 ready:', gotReady);
}

main().catch((e) => { console.error('FATAL', e); process.exit(1); });
