# ph-parser — 后端解析服务

零依赖 Python（只用标准库），把 Pornhub 的解析隔离在一个服务里。
App 只调这个服务的 JSON；Pornhub 一改版，只改这里，不用重新发 App。

端点：`GET /health`、`/api/home?page=`、`/api/search?q=&page=`、
`/api/categories`、`/api/video?viewkey=`、`/api/video_by_id?id=`。
缩略图和视频流**不经过**本服务，App 直接从 phncdn.com 加载，
所以本服务每请求只传几 KB 的 JSON。

## 默认部署方案：Cloady（和 Xray 同一个免费 workspace）

为什么选 Cloady 而不是 Cloudflare Workers / Render（2026-11-22 实测后决定）：

| 方案 | 结论 |
|---|---|
| **Cloady（默认）** | 用户已有账号和正在跑的 Xray（JPN1 免费层）。免费层是整个 workspace 共用 0.5 vCPU / 1 GB / 5 GB，Xray 是个几十 MB 的 Go 程序，再加一个约 60 MB 的 Python 服务能装下；每月 10 GB 流量 / 100 万请求 / 4 CPU 小时——本服务只传 JSON，个人用绰绰有余；7 天无访问才暂停，暂停后 App 内嵌解析兜底（见下）。部署用 Dockerfile 或 GitHub 直连。 |
| Cloudflare Workers | 免费 10 万请求/天、不休眠，但免费层每请求 CPU 上限约 10ms，解析 1.6 MB 详情页可能超；且 Workers 出口 IP 是否被 Pornhub 区别对待**没验证过**。`worker/` 里留了同款 JS 实现做备选，未测试。 |
| Render 免费层 | 15 分钟无访问就休眠，首次打开要等几十秒冷启动，视频 App 体验差；还要新注册账号。 |

部署步骤（需要用户在 Cloady 点几下，因为登录是邮箱验证码，只有他能登；
代码和 Dockerfile 都已备好，他不用写任何东西）：

1. 把 `ph-client` 仓库推到 GitHub（私有即可，见 `../README.md`）。
2. Cloady 控制台 → 同一个 workspace（Xray 所在的）→ New App → 从 GitHub 选
   `ph-client` 仓库，Root Directory 填 `backend`，或直接用仓库里的
   `Dockerfile` 部署。
3. 环境变量不用填（`PORT` 由 Cloady 自动注入；不填默认 8080）。
4. 拿到地址（形如 `https://ph-parser-xxxx.cloady.io`），在 App 的
   设置 → 后端地址里粘贴一次，保存。之后 App 优先走后端。
5. 验证：浏览器打开 `https://<地址>/health` 应返回 `{"ok": true}`；
   打开 `/api/search?q=test` 应返回 30 条视频 JSON。

资源注意：workspace 总量超 0.5 vCPU / 1 GB / 5 GB 会整 workspace 变付费，
所以后端不要加内存缓存以外的东西；本服务常驻内存约 60 MB。

## 如果 Cloady 部署后播不了

先确认是解析挂了还是地址问题：`/health` 通但 `/api/video` 报 502，
说明 Pornhub 改版了，改 `ph_parse.py` 重新部署即可（不用动 App）。

如果 Cloady 整个跑不通解析（比如出口 IP 被拦），**不要让用户自己搭服务器**，
走 App 内嵌解析兜底：App 自带一份同样的解析逻辑（`app/lib/ph_parse.dart`），
后端地址留空时 App 直接解析 Pornhub，装上就能播。代价是 Pornhub 改版后要
重新发 App 包，而不是只改后端。

## 本地运行与测试

```bash
python3 server.py            # 默认 :8080
python3 test_backend.py      # 启动真服务，打真实 Pornhub，逐项断言
```

测试用的是真实请求、无 mock：Pornhub 一改版测试就变红，这正是要的。
