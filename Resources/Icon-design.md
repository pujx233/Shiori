# 图标与界面

图标：内置 image_gen 生成。[原始生成图](../Design/MangaIcon-master.png) / [1024px PNG](MangaIcon.png) / [macOS 图标](MangaIcon.icns)。

macOS 图标包含 16px 到 1024px 的十种标准尺寸，透明区域保留。菜单栏使用 AppKit 绘制的同款单色标记，随系统自动切换明暗。

最终提示：

> Use case: logo-brand. Asset type: one final macOS app icon for a Japanese manga translation utility, square 1:1 canvas, 1024x1024, not a mockup. Design a fresh, restrained editorial identity: a single warm-white speech balloon whose interior is cut into a bold asymmetric manga-panel grid, with one small clean balloon tail. The panel cuts are broad and remain legible at 24px; this should read as one distinctive integrated symbol. Place this mark on a deep jade-green rounded-square tile matching a quiet jade-and-ink macOS interface. Use exceptionally balanced spacing, a crisp silhouette, softly rounded geometry and a very subtle matte tonal finish. The tile occupies about 87% of the canvas, with genuine transparent alpha outside it. The white symbol occupies about 62% of the tile. Front-facing, optically centered, fully contained. Keep the graphic simple and confidently drawn, with very little depth. No book, no overlapping bubbles, no letters or text, no flags, no translation arrows, no sparkle, no mascot, no glass/plastic gloss, no bevels, no outlines around the tile, no busy textures, no checkerboard baked into the image, no surrounding UI, no watermark. Produce only the single finished icon.

界面参考：
- [Bob](https://bobtranslate.com/)：菜单栏快速打开的轻量翻译面板。
- [BallonsTranslator](https://github.com/dmMaze/BallonsTranslator)：气泡内擦字与译文回填。
- [Maccy HeaderView](https://github.com/p0deje/Maccy/blob/master/Maccy/Views/HeaderView.swift)：顶部直接放搜索和操作。
- [Easydict EZTitlebar](https://github.com/tisfeng/Easydict/blob/dev/Easydict/objc/ViewController/View/Titlebar/EZTitlebar.m)：用紧凑图标按钮承载标题栏动作。

界面为原生 AppKit 菜单栏面板，使用墨绿配色与系统菜单。

Shiori 面板以软件、模型、推理三个同级选项开始，不重复显示应用图标与名称。品牌图标保留在系统菜单栏和 Finder 中。

三个选项使用 28pt 标签列，选择框填满剩余宽度；行高 30pt，边框、圆角与字号一致。软件选项内显示 16pt 应用图标。选择菜单从控件下方展开，最小宽度与选择区一致，保留当前选项的勾选；鼠标、键盘和辅助功能使用系统原生下拉行为。

辅助操作放在菜单栏图标的右键菜单，面板里的「软件」也保留相同入口；左键图标打开面板。菜单保留重新翻译、复制译文、返回阅读窗口和退出。实际缺少权限时才显示对应的授权入口。

顶栏右键通过 NSStatusItem.menu 显示，菜单外观跟随 NSApp.effectiveAppearance，使用系统背景、文字和选中颜色；菜单关闭后解除临时关联，保留左键打开面板的行为。

后续图标方向：以 Shiori 的书签含义为主，用单一书签轮廓建立识别。菜单栏版本只保留单色剪影；应用图标使用相同轮廓与墨绿底色。此方向尚未替换当前的漫画气泡图标。
