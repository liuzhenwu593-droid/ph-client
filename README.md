# ph-client — PsexHub 0.2.0

第三方视频客户端：首页、分类、搜索、收藏、离线下载、续播、播放器手势与倍速。不登录。

应用名 PsexHub，包名 `com.liu.phclient`（不变，这样能覆盖安装 v0.1 的 debug 版）。

## 布局

```
ph-client/
  app/        Flutter App（包名 com.liu.phclient，应用名 PsexHub）
  backend/    解析服务（零依赖 Python，可部署到 Cloady）
```

## 目标：用户只装 APK 就能用

- **默认不用后端**：App 自带内嵌解析（`app/lib/ph_parse.dart`），
  后端地址留空时直接连 Pornhub 解析，装上就能播。
- **后端是升级件**：设置里填入后端地址后 App 优先走后端；
  Pornhub 改版后只改后端，不用重新发包；后端挂了自动回落内嵌解析。
- 后端默认部署方案是 **Cloady**（和 Xray 同一个免费 workspace），
  部署步骤见 `backend/README.md`。部署需要用户在 Cloady 点几下
  （登录是邮箱验证码，只有他能登）；代码和 Dockerfile 都已备好。

## 解析验证（2026-11-22，沙盒实测，见 backend 测试输出）

- Webmasters 搜索接口：200，每页 30 条 JSON（标题/时长/播放量/评分/
  标签/分类/封面），无直链。用于列表和搜索。
- 详情页 `flashvars.mediaDefinitions`：240/480/720/1080 四档 HLS。
  签名地址 2 小时过期，每次播放重新获取；110 分钟内重复打开直接用缓存。
- **ev-h / hv-h 双方案**：同一视频随机返回两种 HLS 地址（约各 50%）。
  `ev-h.phncdn.com` 的地址 master.m3u8 返回 200，可播；
  `hv-h.phncdn.com ?h=` 的地址在沙盒里用尽各种请求头都返回 410 Gone。
  解析器（Python 版和 Dart 版）都会重取详情页直到拿到可验证的地址
  （最多 5 次），并且只返回经过 master.m3u8 实测的地址。
  同一次详情页请求里四档清晰度共用同一个 CDN 主机（全是 ev-h 或全是
  hv-h，实测 3 次一致），所以只验证 720p 起播档就够了（v0.2.2 起默认
  720p；v0.2 是 480p），升级 1080p 不用再验。
  后端测试 `backend/test_backend.py` 全部通过（ALL PASS）。
- `/video/get_media` 的 mp4 路线返回 `[]`，已死；老教程的
  flashvars/qualityItems 正则解析不要再抄。
- 同一签名地址用 IPv4 和 IPv6 两种出口 IP 都返回 200，地址不绑定
  请求 IP——后端签发的地址手机上也能播（仍需真机最终验证）。
- `phub` 库（AGPLv3）没用；yt-dlp 只做了逻辑参考，没有抄代码。

## v0.2 快播优化（实测数据）

- 起播档从 1080p 改为 480p（同批地址里最低的 ≥480p 档），只验证这一档；
  v0.2.2 起默认清晰度改为最高 ≤720p 档（有 720p 就 720p，否则 480p/240p），
  手动切换菜单不变，仍可点 1080p。
  详情页请求 1.5–1.9 秒 + 验证 0.2–0.8 秒，每次重试成本不变，但起播更快、
  且缓存命中时 0 秒网络等待（110 分钟内重复打开直接播）。
- 质量切换失败不再杀掉当前播放：新控制器初始化失败就保留旧的继续播，
  只弹提示。

## 国家选择：没做，原因实测过

- Webmasters 搜索接口直接忽略 `country`/`cc` 参数（结果和不带参数一模一样）。
- 站点 `/video?o=mv&t=w&cc=jp` 的 `phCountryCode` 始终是 `US`，
  jp/us/de/br/kr/gb/world 七个值在第 1–3 页、最热和最多播放、XHR、带 session
  cookie 的情况下，列表完全相同（31/31、40/40、41/41 重合）。
- 结论：匿名请求下服务器按请求 IP 所在国家排榜，`cc` 参数改不了榜单，
  App 没法靠传参实现国家切换——做了就是假功能，所以 v0.2 没加国家切换。
  手机上榜单跟的是当前网络出口 IP 所在的国家（即 VPN 节点国家）。

## 搜索筛选：实测结论

- 排序：接口只认 `ordering=mostviewed`。`toprated`/`mostrecent`/`longest`
  返回同一份未排序的默认列表（评分、发布日期都不是降序）。所以“最多播放”
  走服务端排序，“评分最高/最新/最长”在客户端按评分/发布日期/时长排当页结果。
- 时长：接口无时长参数，客户端按 `M:SS` 过滤（短 <5 分钟，中 5–20 分钟，
  长 >20 分钟）。
- 只看高清：没做。搜索接口和 `video_by_id` 都不返回任何高清字段；
  抽查的 4 个视频全部有 720p（3 个有 1080p），高清筛选基本等于不过滤。

## 离线下载（v0.2 新增）

- 下载所选清晰度的 variant playlist 全部 ts 分片，存到 App 专属目录，
  重写一份本地 m3u8，用 ExoPlayer 本地播；不用 ffmpeg、不合并。
- 实测：媒体清单无 `EXT-X-KEY`（分片不加密），158 个分片/10.5 分钟 480p，
  首分片 129,720 字节可正常下载。下载从拿到地址后立刻开始（签名 2 小时过期）。
- 下载管理：进度、取消、删除、已下载列表；一次只跑一个下载。

## 状态（2026-11-22）

- [x] 解析链实测通过（Python 后端测试 ALL PASS；Dart 内嵌解析实测通过）
- [x] 后端服务完成（`backend/`，零依赖，Dockerfile + Cloady 部署说明 + Workers 备选）
- [x] Flutter 0.2.0 完成（快播、收藏、历史/续播、下载、播放器手势、分类、搜索筛选、PIN 锁、新图标、改名 PsexHub）
- [x] GitHub 公有仓库 `liuzhenwu593-droid/ph-client`，CI 出 debug APK
- [ ] 正式签名版：需要新生成专用密钥配到仓库 Secrets，CI 的 release 任务才会出
      signed APK。密钥绝不要提交进仓库，也不要复用其他 App 的密钥。
- [ ] 本 VM 无 Android SDK/JDK，本地无法打包 APK；APK 靠 CI 出
- [ ] 真机验证未做（起播速度、hv-h 在 ExoPlayer 里表现、手势、下载本地播放、PIN 锁）

## 图标与名字

- 图标：用户提供的照片（1080x1080）生成各密度 launcher 图标
  （mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi + adaptive foreground），深色背景。
  原先橙色方块+白三角的占位图标已废弃。
- 应用名：PsexHub（只改显示名，包名 `com.liu.phclient` 不变）。
