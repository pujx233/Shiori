# Shiori

日语漫画翻译，常驻 macOS 菜单栏。

选择正在使用的软件、模型和推理，点「开始阅读」。翻页后自动识字、翻译并回填原位置；取消「显示译文」可查看原图。

- 保留竖排，连体气泡分别排字，译文随返回逐步显示。
- 局部疑点先比对并重识；仍有缺字时用小号灰色 `□`，可读部分继续翻译。整句无法辨认则保留原图，底部统一显示待确认数量。
- 补识别气泡外的拟声词；复杂背景用本地 LaMa 修复，纯色区域直接回填。
- 右键菜单栏图标可补齐译文、重新翻译、重新识字、复制译文和退出。
- 识字在本地完成，Codex 只接收文字，使用已登录的 ChatGPT 账号，无需 API Key。
- 同页复用缓存，翻页取消旧任务并保留连接；缺失条目补译一次。
- 缓存合计上限 256 MiB。近期两页文字用于人名和语气衔接，关闭后清空。

首次使用需要录屏权限；浏览器还需要辅助功能权限。小字、手写字和复杂背景可能识别不全，可右键「重新识字」。

## 安装

从 [Releases](https://github.com/pujx233/Shiori/releases) 下载 Apple Silicon 版，将 `Shiori.app` 放入「应用程序」，在解压目录运行 `SETUP_OCR.command` 安装本地识字组件。

| 浅色 | 深色 |
| --- | --- |
| ![浅色界面](Design/Shiori-panel-light.png) | ![深色界面](Design/Shiori-panel-dark.png) |

## 构建

Apple Silicon、macOS 14+、Codex、Apple Command Line Tools 和 uv。

```sh
./SETUP_OCR.command
./BUILD.command
./build/Shiori.app/Contents/MacOS/Shiori --self-test
./INSTALL.command
```

应用位于 `build/Shiori.app`。本地识字组件保存在 `~/Library/Application Support/Shiori/OCR`。
安装前退出 Shiori。安装脚本会核对名称和签名，避免更新时更换系统授权所绑定的身份。

默认使用固定的本地签名，保存在 `~/Library/Application Support/Shiori Development/Signing`；后续构建复用同一身份。首次从临时签名迁移时需重新授权。签名不会修改系统信任设置。设置 `MANGA_SIGNING_IDENTITY` 可改用已有开发者证书。

首次启动会将旧 KedaTranslate 数据目录迁移到 Shiori，并清理旧偏好设置。

## 开源组件与参考

识字使用 [Manga OCR](https://github.com/kha-white/manga-ocr) 和 [Mokuro / Comic Text Detector](https://github.com/kha-white/mokuro)，版本见 `Resources/ocr-requirements.txt`。

背景修复使用 [LaMa](https://github.com/advimman/lama)，权重来自 [simple-lama-inpainting 的官方发布](https://github.com/enesmsahin/simple-lama-inpainting/releases/tag/v0.1.0)，安装时校验 SHA-256。OCR 按文字长度分批、局部修复与识字并行；未检测为文字框的笔画从已有分割图中补检。

疑点处理参考 [manga-image-translator 的识别质量过滤](https://github.com/zyddnys/manga-image-translator/blob/main/manga_translator/ocr/model_48px.py)，以及 [Mokuro Reader 的原图与文字层分离](https://github.com/Gnathonic/mokuro-reader/blob/main/src/lib/components/Reader/MangaPage.svelte)。两套本地识别结果一致时直接确认；仍有分歧时只重识对应的小区域，每页最多四次。不确定片段单独记录，字号适配、流式回填和缓存都保留这一状态。

排版参考 [BallonsTranslator](https://github.com/dmMaze/BallonsTranslator) 与 [manga-image-translator](https://github.com/zyddnys/manga-image-translator) 的文字方向和区域适配；连接管理参考 [Easydict](https://github.com/tisfeng/Easydict)；界面参考 [Ice](https://github.com/jordanbaird/Ice) 与 [Settings](https://github.com/sindresorhus/Settings) 的对齐、分组和系统控件。
