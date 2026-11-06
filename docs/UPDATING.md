# 自动更新（Sparkle）与发布页

## 小屋风格包（手动维护，不属于发版脚本）

温馨木屋始终内置在 SwiftPM resource bundle。其余四包默认仍随 App 打包；R2 尚未上传时不要切换精简模式。
此流程不修改版本号、appcast 或 Sparkle，不需要把任何 R2 凭据写入仓库。

1. 素材变更时更新 `assets/house/styles/<id>/manifest.json` 的整数 `version`；已经上传的版本路径不可覆盖。
2. 执行 `scripts/build-style-packs.sh`（或指定输出目录）。输出 `dist/style-packs/<id>/<version>.zip` 和 `index.json`，
   同时生成 `Sources/MijiaBarApp/Resources/House/style-packs.json`。将该小型索引与素材修改一起提交，不提交 ZIP。
3. 执行 `scripts/build-style-packs.sh --check`：在临时目录重新构建，核对签入索引里的 SHA-256 和字节数。
   构建按路径排序、固定 2020-01-01 时间戳、固定 UNIX 文件权限、无 extra/comment 元数据（等效 `zip -X`）。
   使用 ZIP_STORED，PNG 本身已经压缩；避免 zlib/zip 版本差异改变哈希。同一输入字节产生完全相同的 ZIP。
4. 维护者在已认证的本机手动上传到绑定 `files.neardws.com` 的 R2 bucket，例如：

   ```bash
   scripts/build-style-packs.sh
   # BUCKET 是维护者的实际 bucket 名称；不要在脚本或仓库保存凭据。
   for id in japanese modern light-wood walnut; do
     version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "assets/house/styles/$id/manifest.json")
     wrangler r2 object put "$BUCKET/mijiabar/house/styles/$id/$version.zip" --remote \
       --file "dist/style-packs/$id/$version.zip" --content-type application/zip
   done
   wrangler r2 object put "$BUCKET/mijiabar/house/styles/index.json" --remote \
     --file dist/style-packs/index.json --content-type application/json
   ```

   也可以使用 R2 Dashboard 上传同样的 object keys。远端 index 方便维护者查看，客户端只信任随签名 App 内置的索引。
5. 维护者核对 HTTPS 公开 URL 可直接访问（不重定向），下载字节数和 SHA-256 与索引一致后，才使用
   `HOUSE_STYLE_BUNDLE=default scripts/package.sh`。默认 `HOUSE_STYLE_BUNDLE=all` 行为保持不变。
   `package.sh` 会清空 `dist/`，因此先上传或将包构建到独立目录，再进行 App 打包。
6. `scripts/verify-app-bundle.sh <App>` 总是检查默认素材与内置索引；指定 `HOUSE_STYLE_BUNDLE=all|default` 可验证
   对应模式，不指定时自动检测。可选风格仅出现一部分会失败。不要通过本步骤发布 App 或生成 appcast。

### 体积实测（当前四包 version 1）

`du -sk assets/house/styles/<id>/{modules,classic}`（不存在的 classic 忽略）与脚本 ZIP 输出：

| 风格 | modules + classic 磁盘占用（KiB） | ZIP 字节数 | 下载显示（MB，十进制） |
| --- | ---: | ---: | ---: |
| Japanese | 6,116 | 6,122,702 | 6.1 |
| Modern | 6,400 | 6,407,726 | 6.4 |
| Light wood | 9,524 | 9,563,089 | 9.6 |
| Walnut | 8,848 | 8,892,488 | 8.9 |
| 总计 | 30,888 | 30,986,005 | 31.0 |

精简模式移除约 30.2 MiB 的四包素材磁盘占用（不含极小的 manifest），而非声称 DMG 恰好缩小同样数值；
DMG 压缩、文件系统分配与签名都会影响最终大小。本次仅测量素材与 ZIP，未打包、公证或发布。

## Sparkle

应用内嵌 [Sparkle 2.10](https://sparkle-project.org/)（MIT）。`Info.plist`：

| 键 | 值 |
| --- | --- |
| `SUFeedURL` | `https://github.com/leotpp/MijiaBar-Fork-Plus/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` | 本 fork 的 EdDSA 公钥，见 `Resources/Info.plist`（可提交） |

**私钥**只在维护者机器上：

```
~/mijiabar-private/sparkle/eddsa_priv.key
```

私钥文件权限应为 `0600`；签名脚本通过 `--ed-key-file` 使用它。切勿把私钥或 `~/mijiabar-private/` 提交进仓库、写入日志或作为 Release 资产上传。

### ad-hoc 发版流程

1. 执行 `VERSION=0.1.18 SIGN_IDENTITY=- scripts/package.sh`（后续替换版本号）。脚本先对 App 做完整 ad-hoc 代码签名与凭据扫描，门禁通过才生成 `dist/MijiaBar-0.1.18-unsigned.dmg`，再用自有 EdDSA 私钥签名更新档案，输出 `docs/appcast.xml` 与相同内容的 `dist/appcast.xml`。无需 Apple 公证；有 Developer ID 时仍按原流程签名、公证。`SKIP_APPCAST=1` 可显式跳过更新源生成。
2. 检查凭据门禁、`codesign --verify --strict --verbose=2 dist/MijiaBar.app` 与 appcast 中的版本、下载 URL、EdDSA 签名。App 只能使用客户自己扫码后保存在其钥匙串的凭据，不能复制维护者的 session、设备缓存或偏好到产物。
3. 创建本仓库 GitHub Release `v0.1.18`，**同时上传 DMG 和 `dist/appcast.xml`**，后者资产名必须为 `appcast.xml`。`latest` feed 依赖 GitHub 将该正式 Release 识别为最新版本；草稿或预发布不作为此 feed 的发版流程。
4. 发布后核对上述 feed URL 和 appcast 的 DMG URL 可下载。客户端按既有设置自动检查，也可手动检查更新；安装更新仍遵循 Sparkle 提示。
5. 如需同步网站版本，运行 `python3 scripts/gen-site.py`（版本号来自 `docs/appcast.xml`），另行提交生成文件；客户端 feed 由 GitHub Release 资产提供。

ad-hoc 更新仍要求下载后 App 自身代码签名完整，且内置 `SUPublicEDKey` 与本 fork 的签名私钥匹配。EdDSA 签名不替代首次安装时的 macOS 隔离检查。

### 首次迁移与密钥轮换

**0.1.17 及更早仍携带上游 feed 和公钥，须手动安装一次 0.1.18，之后才能从本 fork 接收自动更新。** 更早没有 Sparkle 的版本也必须手动迁移。

**直接更换 EdDSA 密钥会让信任旧公钥的安装无法自动更新，用户需要手动安装一次携带新公钥的版本。** 保管好当前私钥，不要在每次发版时重新生成；不要移除 App 的公钥。计划无缝轮换时须另行设计并验证 Sparkle 的迁移流程。

### 仅重签 appcast

```bash
VERSION=x.y.z DMG_PATH=dist/MijiaBar-x.y.z-unsigned.dmg scripts/generate-appcast.sh
```

脚本也支持不带 `-unsigned` 的 DMG，下载 URL 保留实际文件名。默认仓库为 `leotpp/MijiaBar-Fork-Plus`；可用 `RELEASE_REPO`、`APP_LINK`、`DOWNLOAD_URL_PREFIX` 或 `DOWNLOAD_URL` 覆盖归属与下载地址，App 中的 `SUFeedURL` 需另行同步。

仅本地试跑时同时覆盖两份输出，避免改动正式 feed：

```bash
APPCAST_PATH=/tmp/mijiabar-appcast.xml RELEASE_APPCAST_PATH=/tmp/mijiabar-release/appcast.xml \
  DMG_PATH=dist/MijiaBar-0.1.17-unsigned.dmg scripts/generate-appcast.sh
```

## 上游同步

本地 `origin` 指向上游 `https://github.com/neardws/MijiaBar.git`，`fork` 指向自己的 `leotpp/MijiaBar-Fork-Plus`。工具不会修改 remote，也不会 push、发布或打 tag；运行前可用 `git remote -v` 核对。

### 手动检查与合并

```bash
scripts/sync-upstream.sh          # 默认 --check，只 fetch 和报告差异
scripts/sync-upstream.sh --check  # 上游/本地各领先多少，以及未合并的上游提交
scripts/sync-upstream.sh --merge  # 同样先检查，再双父合并 origin/main 到当前分支
```

有无新提交时检查都返回 0；拉取失败返回非零并明确报错。合并要求工作树干净，请先切换到要同步的分支。无冲突时 Git 自动创建 merge commit；冲突时脚本返回非零并保留现场，不自动解决或提交，可手动解决后提交，或用 `git merge --abort` 撤销。本 fork 的额外提交会计入「本地领先」，不代表需要删除或回退。

### 自动提醒

`.github/workflows/upstream-watch.yml` 每周一 UTC 03:23 检查一次，也可从 Actions 手动运行 `workflow_dispatch`。它读取 fork 的 `main`，显式拉取上游 main（CI 的 origin 是 fork），有新提交时创建或更新固定标题「上游 MijiaBar 有新提交」的未关闭 issue，正文包含提交列表及本地合并命令；没有新提交时不操作 issue。拉取失败只记录 workflow 错误，不创建提醒。只授予 `contents: read` 和 `issues: write`；并发检查串行执行，避免重复创建。文件推送到 fork 默认分支后才生效，须在仓库启用 Actions 和 Issues。此提醒不自动判定提交是否重要，也不自动合并或发布。

### 合并后检查清单

- [ ] 运行 `python3 scripts/gen-readme.py`，核对三个 README 最前面的 fork 更新记录（目前 0.1.19、0.1.18、0.1.17）仍保留，上游条目在其后，不手改生成 README。
- [ ] 若 `i18n/*.tsv` 或 `Sources/MijiaCore/Translations.swift` 有变化，运行 `python3 scripts/gen-i18n.py`，以源表生成结果为准。
- [ ] 检查 `docs/appcast.xml` 的版本、下载 URL、签名仍属于本 fork；`Resources/Info.plist` 的 `SUFeedURL` 应为本 fork Releases feed，`SUPublicEDKey` 保持本 fork 公钥，`SUAutomaticallyUpdate` 保持 false。不因同步上游而改动 App 的检查/安装行为。
- [ ] appcast 被上游覆盖时先恢复本 fork 已发布的原件；只有持有对应 DMG、确需重签时才运行 `scripts/generate-appcast.sh`（默认输出 `docs/appcast.xml`，同时生成 `dist/appcast.xml`），核对版本/签名，不为代码同步重新签署旧发布。
- [ ] 核对 `.github/workflows/build.yml`、`scripts/package.sh`、`scripts/scan-*.sh`、`scripts/generate-appcast.sh` 的 fork 发布归属、凭据门禁与签名流程没有回退。
- [ ] 运行 `swift build`、`scripts/test.sh`、`scripts/scan-secrets.sh`、`git diff --check`。上游改 UI 时运行 `.build/debug/MijiaBarApp --snapshot /tmp/mijiabar-upstream-shots -AppleLanguages "(zh-Hans)"` 并查看浅/深色演示图，不提交真实设备快照。
- [ ] 保留 merge 双父历史；若自动合并已经提交，生成物修正和验证结果可另作后续提交。推送、tag、Release 与安装仍由维护者另行决定，自己的发布继续上传到本 fork Releases。

### 已知冲突热点

- `scripts/gen-readme.py` 的三语更新列表及三个生成 README：两边都会添加更新条目，脚本与生成物须一致。
- `i18n/zh-Hant.tsv` 和 `Sources/MijiaCore/Translations.swift`：新增字符串可能重叠，先合并源表再生成。
- `Resources/Info.plist`、`docs/appcast.xml` 与发布/扫描脚本：上游 feed、公钥、版本及发布归属不能覆盖 fork 配置。
- `Sources/MijiaBarApp/TypeDetails.swift`、`AppModel.swift` 及 `Sources/MijiaCore/XiaomiCloud.swift`：上游设备详情/控制演进可能与 fork 的会话续期、更新器调整相交，须结合测试核对行为。

## GitHub Pages

站点文件在 `docs/`：`index.html`（英文）和 `zh-CN.html`（简体中文），由 `scripts/gen-site.py` 根据 `site/template.html` 和 `i18n/site/*.json` 生成，不要直接改（繁体中文等页面稳定后再加，译稿在 `i18n/site/drafts/zh-Hant.json`）；图片在 `docs/assets/`（`scripts/site-shots.sh` 生成）；另有 `appcast.xml`。

根页面会按 `?lang=`、访客在语言菜单里的选择、浏览器语言依次决定是否跳转到中文页面（繁体中文浏览器也去简体页面）；旧链接 `index.html?lang=zh` 仍然有效。

仓库设置 → Pages → Source = **Deploy from a branch** → Branch **`main`** / folder **`/docs`**。

首次启用也可用：

```bash
gh api repos/neardws/MijiaBar/pages -X POST \
  -f build_type=legacy \
  -F 'source[branch]=main' \
  -F 'source[path]=/docs'
```

公开地址：<https://www.neardws.com/MijiaBar/>
