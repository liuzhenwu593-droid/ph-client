# ph-client — PH Player 最小版

第三方视频客户端：首页 + 搜索 + 播放。不登录、不下载、不收藏。

## 布局

```
ph-client/
  app/        Flutter 最小版 App（包名 com.liu.phclient，应用名 PH Player）
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
  签名地址 2 小时过期，每次播放重新获取。
- **ev-h / hv-h 双方案**：同一视频随机返回两种 HLS 地址（约各 50%）。
  `ev-h.phncdn.com` 的地址 master.m3u8 返回 200，可播；
  `hv-h.phncdn.com ?h=` 的地址在沙盒里用尽各种请求头都返回 410 Gone。
  解析器（Python 版和 Dart 版）都会重取详情页直到拿到可验证的地址
  （最多 5 次），并且只返回经过 master.m3u8 实测的地址。
  后端测试 `backend/test_backend.py` 全部通过（ALL PASS）。
- `/video/get_media` 的 mp4 路线返回 `[]`，已死；老教程的
  flashvars/qualityItems 正则解析不要再抄。
- 同一签名地址用 IPv4 和 IPv6 两种出口 IP 都返回 200，地址不绑定
  请求 IP——后端签发的地址手机上也能播（仍需真机最终验证）。
- `phub` 库（AGPLv3）没用；yt-dlp 只做了逻辑参考，没有抄代码。

## 状态（2026-11-22）

- [x] 解析链实测通过（Python 后端测试 ALL PASS；Dart 内嵌解析实测通过：
  搜索 30 条 + 详情 4 档 HLS，`dart run` 输出 ALL DART PARSER CHECKS DONE。
  注：第一次 Dart 实测遇到一次 30 秒超时（偶发，类似后端测试也遇到过一次
  偶发 502），重跑即通过——解析层都有重试和回落，正是为这种抖动准备的）
- [x] 后端服务完成（`backend/`，零依赖，Dockerfile + Cloady 部署说明 + Workers 备选）
- [x] Flutter 最小版完成（`app/`，CI workflow 已备好）
- [x] GitHub 仓库已创建：公有 `liuzhenwu593-droid/ph-client`（2026-11-22，用户确认公有）
- [ ] 未生成签名密钥——CI release 打包需要用户在仓库 Secrets 里配
- [ ] 本 VM 无 Android SDK/JDK，本地无法打包 APK；APK 靠 CI 出
- [ ] 真机验证未做（播放、清晰度切换、后端回落、hv-h 在 ExoPlayer 里表现）

## 建议的仓库

- 名：`ph-client`，**公有**（用户 2026-11-22 确认）
- 账号：`liuzhenwu593-droid/ph-client`
- 等用户确认后：创建仓库 → 推代码 → 在 Secrets 配新签名密钥 → 手动触发一次 CI
  → 从 rolling release `ci-latest` 拿 debug APK 先装机验证。
