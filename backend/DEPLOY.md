# 部署 ph-parser 到 Cloady（用户自己操作，约 5 分钟）

后端是一个零依赖 Python 服务（只用标准库）：解析 Pornhub、返回 JSON，
App 填了这个地址后优先走后端；Pornhub 再改版只改后端重新部署，不用重新发 App。
缩略图和视频流不经过后端，App 直接从 phncdn.com 加载。

## 需要的东西

- Cloady 账号（和 Xray 同一个 workspace，免费层即可）
- 这个仓库已推到 GitHub（`ph-client`，`backend/` 目录里有 `Dockerfile` + `server.py`）
- 不用填任何环境变量：`PORT` 由 Cloady 自动注入，不填默认 8080；
  服务监听 `0.0.0.0:$PORT`

## 步骤（Cloady 控制台，登录是邮箱验证码，只有你能登）

1. Cloady 控制台 → 和 Xray 同一个 workspace → New App。
2. 从 GitHub 选择 `ph-client` 仓库，Root Directory 填 `backend`
   （或直接用仓库里的 `Dockerfile` 部署——按控制台给的选项选一种）。
3. 环境变量不用填。部署，等它变成 Running。
4. 拿到地址（形如 `https://ph-parser-xxxx.cloady.io`）。
5. 打开手机 App → 设置 → 后端地址，粘贴这个地址，保存，点“测试连接”。
   显示“后端连通”就好了；之后 App 优先走后端。

> 注意：Cloady 控制台的具体按钮文字可能和上面写的不完全一样，
> 按意思找（新建应用 / 选仓库 / 填目录 / 部署）；如果某一步找不到，
> 截图发回来再对。

## 验证（浏览器打开就行）

- `https://<你的地址>/health` 应返回 `{"ok": true, ...}`
- `https://<你的地址>/api/home?page=1` 应返回 30 条左右视频 JSON
- `https://<你的地址>/api/search?q=test` 应返回 30 条视频 JSON

## 如果出问题

- `/health` 通但 `/api/home` 或 `/api/video` 报 502：Pornhub 改版了，
  改 `backend/ph_parse.py` 重新部署即可（不用动 App、不用重新装）。
- 整个部署后 App 播不了：先把 App 设置里的后端地址清空，
  App 会自动回落到内嵌解析，照常能播。
- Cloady 免费层是整个 workspace 共用资源（0.5 vCPU / 1 GB / 5 GB 储存，
  每月 10 GB 流量 / 4 CPU 小时），本服务常驻内存约 60 MB、每请求只传
  几 KB 的 JSON，个人用够用；7 天无访问服务会暂停，App 会自动回落到
  内嵌解析，下次访问时再唤醒。

## 本地自测（已验证过，不用你跑）

```bash
cd backend
python3 server.py            # 默认 :8080
python3 test_backend.py      # 启动真服务，打真实 Pornhub，逐项断言
```

2026-11-25 本地实测：`/health`、`/api/home`（31 条）、`/api/search`
（各排序 30 条）、`/api/category?id=37`（30 条）、`/api/video`
（5 个源，含 240/480/720/1080 HLS）、`/api/video_by_id` 均通；
`/api/categories` 当时因沙箱到 Pornhub 的连接反复被重置没测通，
App 侧有内嵌分类兜底，不影响部署。
