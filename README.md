# Shiori

常驻 macOS 菜单栏的日语漫画翻译工具，翻页后自动识字并在原位置显示中文译文。

| 浅色 | 深色 |
| --- | --- |
| ![浅色界面](Design/Shiori-panel-light.png) | ![深色界面](Design/Shiori-panel-dark.png) |

## 安装

支持 Apple Silicon，macOS 14 及以上。

1. 从 [Releases](https://github.com/pujx233/Shiori/releases/latest) 下载 DMG。
2. 打开后将 Shiori 拖到 Applications。
3. 启动 Shiori，安装识字组件，并按提示开启录屏和辅助功能权限。

Google 可直接使用。使用 Codex 需先安装并登录 Codex，点击「模型 ▸」可选择模型与推理档位。

## 使用

打开漫画，选好阅读软件和翻译服务，点击「开始阅读」；再次点击可暂停。切到其他软件时保留已有译文，回到漫画后继续翻译。

| 操作 | 快捷键 |
| --- | --- |
| 临时查看原图 | 按住 ⌥ |
| 临时查看译文 | 鼠标指向文字，按住 ⌃⇧ |
| 修正气泡 | ⌃⌥E |
| 撤销修正 | ⌃⌥Z |
| 重做修正 | ⌃⌥⇧Z |

右键可重新翻译、修正气泡、编辑作品用词或打开设置。「阅读」菜单提供重新识字和复制译文。

「作品用词」可统一人名和称呼，Codex 还可设置翻译风格。组件安装、缓存清理和应用更新都在右键的「设置」中。

## 开发

构建需要 Apple Command Line Tools 和 [uv](https://github.com/astral-sh/uv)。

```sh
./SETUP_OCR.command
./BUILD.command
./build/Shiori.app/Contents/MacOS/Shiori --self-test
./INSTALL.command
```

应用生成在 `build/Shiori.app`，安装前退出正在运行的 Shiori。生成 DMG：

```sh
python3 Scripts/create_dmg.py build/Shiori.app
```

## 致谢

识字与去字使用 [Manga OCR](https://github.com/kha-white/manga-ocr)、[Mokuro](https://github.com/kha-white/mokuro)、[LaMa](https://github.com/advimman/lama) 和 [simple-lama-inpainting](https://github.com/enesmsahin/simple-lama-inpainting)。

功能与界面参考了 [BallonsTranslator](https://github.com/dmMaze/BallonsTranslator)、[Koharu](https://github.com/koharu-rs/koharu)、[manga-image-translator](https://github.com/zyddnys/manga-image-translator)、[manga-translator-ui](https://github.com/hgmzhn/manga-translator-ui)、[Mokuro Reader](https://github.com/Gnathonic/mokuro-reader)、[Easydict](https://github.com/tisfeng/Easydict)、[Ice](https://github.com/jordanbaird/Ice) 和 [Settings](https://github.com/sindresorhus/Settings)。
