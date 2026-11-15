# ZooCove 发版

## 本地体验包

在 macOS 15 或更新版本使用安装了 Swift 6 的 Xcode。生成的 DMG 包含应用和 Applications 快捷方式。

```sh
swift test
Scripts/package-release.sh --local
version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
cd dist
shasum -a 256 -c "ZooCove-$version-local.dmg.sha256"
```

`-local.dmg` 使用临时签名，可用于本机体验或标明签名状态的公开预览。正式公证版走 Developer ID 和 Apple 公证流程。

从 NotchZoo 升级时，先退出旧版，再打开 ZooCove。头像和实例设置会自动保留。已安装过头像技能的用户，可在设置里点一次「安装 Codex 头像技能」更新应用路径。

## 发布预览版

将本机验证过的通用 DMG 复制为 `ZooCove.dmg`，生成对应的 SHA-256 校验文件，再通过 GitHub Releases 上传。勾选 **Set as a pre-release**，在发布说明中写明临时签名及 Apple 公证状态。在 [docs/index.html](docs/index.html) 的 `zoocove-preview-tag` 中填写对应版本标签，首页会直接下载该版本。

## 发布公证版

1. 在项目仓库确认 `Resources/Info.plist` 的版本和递增的构建号。准备 [更新记录](CHANGELOG.md)，展示截图使用测试会话。
2. 在钥匙串安装团队的 **Developer ID Application** 证书和配对私钥。Apple Development 证书用于开发，公开分发需要 Developer ID。
3. 将 Apple 公证凭证保存在钥匙串。使用团队资料和 Apple 生成的 App 专用密码，按提示操作。

```sh
xcrun notarytool store-credentials ZooCoveNotary \
  --apple-id 'Apple 账号' --team-id '团队 ID'
```

4. 运行正式打包命令。脚本启用 Hardened Runtime 和安全时间戳，签名应用和 DMG，提交公证，附加票据，检查 Gatekeeper，再生成校验值。

```sh
ZOOCOVE_DEVELOPER_ID='Developer ID Application: 团队名 (团队ID)' \
ZOOCOVE_NOTARY_PROFILE=ZooCoveNotary \
Scripts/package-release.sh --public
```

5. 在一台未安装过 ZooCove 的 Mac 上，验证浏览器下载后的 DMG 能挂载，拖入「应用程序」后能打开。验证空刘海、多个活动会话、跳转和角色切换。通用包包含 Apple 芯片与 Intel 两种架构，运行体验分别验证。
6. 从已提交、已审核的对应版本创建 GitHub Release 草稿，上传公证通过的 DMG 和校验值，填入版本说明后发布。

```sh
version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
cp "dist/ZooCove-$version.dmg" dist/ZooCove.dmg
(cd dist && shasum -a 256 ZooCove.dmg > ZooCove.dmg.sha256)
gh release create "v$version" --draft --target main \
  --title "ZooCove $version" \
  dist/ZooCove.dmg \
  dist/ZooCove.dmg.sha256
```

Apple 公证和签名用于 macOS 的信任校验。GitHub Releases 托管版本及文件。Perch 还使用 Sparkle 为自动更新 ZIP 单独签名，并把更新记录写入 appcast。ZooCove 首发可以用同一仓库托管源码与 DMG，用户从 Release 手动更新。

## 产品页

在 GitHub 仓库的 **Settings → Pages** 选择 **Deploy from a branch**，来源选 `main` 和 `/docs`。发布后把 Pages 地址填入仓库 About 的 Website。

产品页会根据标准的 `owner.github.io/repo/` 地址找到对应仓库。使用自定义域名或根站点时，在 [docs/index.html](docs/index.html) 的 `zoocove-repository` 元数据里填入实际的 `owner/repo`。发布公证版后清空 `zoocove-preview-tag`，Download 就会通过 `releases/latest/download/ZooCove.dmg` 下载最新稳定版。每次公开发版都沿用这两个上传文件名。

参考 [GitHub Pages 发布来源](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site) 和 [GitHub Release 下载链接](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)。

参考 [Apple 分发打包指南](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)、[Perch 下载页](https://github.com/asafofer/perch-releases/releases/latest)、[Perch 更新订阅](https://github.com/asafofer/perch-releases/blob/main/appcast.xml)。
