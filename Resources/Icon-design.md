# 图标与界面

图标只使用日文假名「あ」。应用图标采用墨绿底、白色现代圆体字标，底色由 `#2E7369` 过渡到 `#113D40`；菜单栏沿用同一圆体轮廓，以单色显示并跟随系统切换明暗。

构图参考 [Easydict](https://github.com/tisfeng/Easydict) 的圆润笔画与清楚字腔，以及 [Pot](https://pot-app.com/) 以文字建立翻译工具辨识度的处理。最终保留一个假名、均匀留白和轻微底色层次，字形使用 Hiragino Maru Gothic 的矢量轮廓。

视觉方向通过内置 imagegen 探索，最终使用系统日文字形的矢量轮廓重绘，保持字符准确与透明边缘干净。[探索提示词](../Design/ShioriIcon-prompts.md)。

[SVG](../Design/ShioriIcon.svg) / [应用预览](../Design/ShioriIcon-preview.png) / [菜单栏明暗预览](../Design/ShioriIcon-menubar-preview.png) / [1024px PNG](ShioriKanaIcon.png) / [macOS 图标](ShioriKanaIcon.icns)。macOS 图标包含 16px 到 1024px 的十种标准尺寸，并保留外部透明区域。

矢量源在 `Sources/ShioriIcon.swift`，应用与菜单栏使用同一个假名，各自适配显示尺寸。用 `Scripts/GenerateIcons.swift` 生成 SVG、PNG、ICNS 与预览：

```sh
xcrun swiftc -swift-version 5 -O Sources/ShioriIcon.swift Scripts/GenerateIcons.swift -framework AppKit -o /tmp/shiori-generate-icons
/tmp/shiori-generate-icons "$PWD"
rm /tmp/shiori-generate-icons
```

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
