# DSH Go for iOS

在 iPhone / iPad 上用 DSH —— 复刻 [xiazhi88/dshgo](https://github.com/xiazhi88/dshgo) 的
Android 客户端，**连你自己电脑上跑着的 dsh 桌面端**。

```
┌─────────┐        局域网 / Tailscale        ┌──────────────────────┐
│ iPhone  │ ────────────────────────────────> │ dshgo :3081          │
│  DSH Go │ <──────────────────────────────── │   ↓ 改写成 loopback  │
└─────────┘                                   │ dsh web  :3080       │
                                              └──────────────────────┘
```

手机不直连 `127.0.0.1:3080`（`dsh web` 只绑 loopback，且 `/api` 有 Host/Origin 栅栏），
而是连插件的转发端口 `3081` —— 插件把入站请求的 Host/Origin 统一改写成
`127.0.0.1:3080`，栅栏永远看到 loopback，cookie 绑定的 authority 也始终一致。

## 装插件（电脑侧）

```sh
dsh plugin --profile web add github:xiazhi88/dshgo -w
# 然后重启 dsh web —— 后端半只在启动时挂载
dsh web
```

装完打开 `http://127.0.0.1:3080` → 设置 → **局域网访问**，里面有机地址和二维码。

## App 里有什么

| 功能 | 说明 |
|---|---|
| **连接列表就是首页** | 多台电脑各存一条，一眼看到在线状态、延迟、插件版本、要不要解锁，点一下切过去 |
| **会话 + 审批** | `session/list` + `/api/remote.mux` 事件流实时同步；卡在审批上时通知栏直接给「允许 / 拒绝」 |
| **通知栏点头** | 点按钮不会把 App 拉到前台 —— 你的意图只是点个头，不是要去看 DSH |
| **DSH 界面** | `dsh web` 的界面跑在 WebView 里，带布局覆盖（手机抽屉 / 电脑布局） |
| **语音输入** | 状态条麦克风按钮，边说边出字，直接灌进 DSH 的输入框 |
| **访问密码** | 原生解锁界面；密码是根凭据，第一次必须先输一次 |
| **多地址自动选路** | 家里局域网、出门 Tailscale 都记着；当前地址能用就不动，连不上才切 |
| **前台不接管** | DSH 页面在前台时审批交给页面，两边不抢答 |

## 协议

按 Android 侧实测验证过的 `android/docs/PROTOCOL.md` 复刻：

| 通路 | 形状 |
|---|---|
| 探测 | `GET /__dshgo__/info` + `GET /__dshgo__/auth/status`（都不需要先解锁） |
| 握手 | `GET /` 跟重定向、收 `Set-Cookie: dsh-auth-…`，再桥接进 `WKHTTPCookieStore` |
| 解锁 | `POST /__dshgo__/unlock`（JSON `{password}`）→ `Set-Cookie: dshgo-unlock` |
| 一元 RPC | `POST /api/<ns>/<method>`，信封 `{type:'client-request', rpcId, method, payload:{args}}` |
| 事件流 | `ws://…/api/remote.mux`，发 `{type:'open', streamId, endpoint:'$events', payload:{args:{}}}` |

要点（都是踩过的）：

- **端点用斜杠不是点**：`session/list` ✓ / `session.list` ✗
- **waterfall 必须回执**：`approval/request` 是 waterfall 模式，宿主会等每个订阅者表态。
  不接管的帧立刻回 `{kind:'next'}`，否则宿主的 waterfall 一直挂着，**把用户的审批卡住**。
- **回执只有两种合法 outcome**：`{kind:'next'}` / `{kind:'result', value}`
  （审批的 value 取 `allowed-once` / `rejected`）。
- **UA 决定界面不决定权限**：带 `DSHGo` 宿主给 JSON，否则给密码页。伪造 UA 没有收益。
- **握手每一跳都要带 cookie**：不带会 303 → `/` → 303 无限循环
  （launch token 换 cookie 后上游回 303，`location` 是相对路径 `/`）。

## DSH 版本要求

最低 **`0.1.2-rc.1`**。`session/list` RPC 与 `/api/remote.mux` 事件流都是
`0.1.2-alpha.2` 才加的；版本过老时 App 会明确告诉你去升级，不静默空转。

## 自检

```sh
node tools/probe-api.mjs http://127.0.0.1:3081
```

打一遍探测 / 握手 / `session/list` / 事件流，四步全通说明链路是好的。

## 构建

```sh
# 本机（有 Xcode 的 Mac）
xcodegen && open DSHGo.xcodeproj

# 没有 Mac：GitHub Actions 出未签名 ipa
powershell -File scripts/publish-github.ps1 -Token $env:GITHUB_TOKEN -Private
# 然后下载 artifact，用全能签/ESign 重签侧载
python scripts/upload-to-qnq.py build/*-unsigned.ipa
```

未签名 ipa 不能直接装，必须重签；工程里所有签名相关设置都刻意留空。

## 许可

MIT。协议与功能按 dshgo（MIT）复刻；移动端布局思路内联自
`dsh-web-mobile`（MIT，Copyright (c) 2026 mexiaosqwq）。
