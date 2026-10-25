# 图标与界面

应用图标采用墨绿底与错位双气泡，左上「あ」、右下「文」，构图参考 [Apple 翻译](https://apps.apple.com/us/app/translate/id1514844618)。已确认的第一稿保存在 [ShioriArtwork.png](ShioriArtwork.png)，打包时生成带透明外缘的 macOS 图标。

菜单栏单独绘制为 22 × 18 pt 的「双气泡＋あ」：前方气泡内保留一个假名，后方用空心轮廓。模板图像使用黑色与透明色，由系统处理浅色、深色和选中状态。

[应用预览](../Design/ShioriIcon-preview.png) / [菜单栏明暗预览](../Design/ShioriIcon-menubar-preview.png) / [顶栏矢量](../Design/ShioriIcon-menubar.svg) / [1024px PNG](ShioriAppIcon.png) / [macOS 图标](ShioriAppIcon.icns)。

主图标采用确认的位图稿，布局 SVG 内嵌同一 PNG；菜单栏 SVG 使用字体轮廓与图形路径。绘制与打包源位于 `Sources/ShioriIcon.swift`，通过以下命令生成资源：

```sh
xcrun swiftc -swift-version 5 -O Sources/ShioriIcon.swift Scripts/GenerateIcons.swift -framework AppKit -framework CoreText -o /tmp/shiori-generate-icons
/tmp/shiori-generate-icons "$PWD"
rm /tmp/shiori-generate-icons
```

[图像生成记录](../Design/ShioriIcon-prompts.md)。

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

品牌图标仅出现在系统菜单栏与应用图标中，面板内继续保留紧凑的原生控件布局。
