# 发现页底部交流入口 · iOS 移植验收

入口位于 **发现 → 页面底部 → 交流与分享**。聊天室打开现有 `ChatRoomListView`；社区进入标题为“广场”的未开放提示页。按本次确认范围，原生广场留待后续移植。

## 基准与实现

Android 基准为 `Pixiv-Shaft` 提交 `1991008f821df6d508ac7ed1dee4d856c439887a`，参考 `FragmentCenter.java`、`fragment_new_center.xml`、`DiscoverSocialSection.kt`、`DiscoverSocialArtView.kt` 和 `V3Palette.kt`，遵循 `docs/v3-design-philosophy.md` 的发现页交流入口规范。

- 页边距 20、模块顶距 28、标题与卡片间距 16、卡片间距 12、圆角 22；卡内上 / 左 / 右边距 16，底边距 14。
- 扣除页边距后的内容宽度达到 332、字体倍率不超过 1.3 时使用等高双列。其他情况单列；单列宽度达到 264 且正常字体时，采用左文右图。
- 原始插图画布 142 × 140；路径、旋转角度、透明度色阶与局部投影用原生 Core Graphics 复现。文字与点击区域使用原生 UILabel / UIControl。
- Montserrat 使用项目已有真实字体，中文使用系统加权回退。按 Android 的字号、字重、字距、行框和换行间距测量；支持系统大字体。
- 默认强调色沿用 Android 的 `#686BDD`，其他颜色按同源染色与对比度公式推导，文字按最终背景校正到至少 4.5:1。没有更改 iOS 全局主题；组件支持注入主色，预览可对照 Android 自定义色。
- 整张卡片是一个可访问按钮，箭头共用点击区域。按压缩放为 0.96，按下 / 释放时长 120 / 200ms；减少动态效果时取消缩放。
- 简中、繁中、英、日、韩、俄、土七种语言直接同步 Android 资源。

沿用 Android 当前入口位置，移除了“更多”中的旧聊天室入口和两个实验性入口开关。聊天室消息横幅开关保留原有存储键并独立展示。新模块本身不加载数据；导航使用发现页既有的 `NavigationStack`。

## 校验与复现

2026-09-18：

- `build/discover-social-final.xcresult`：4 项 UI 测试全部通过，覆盖两个真实目标页面及返回、浅 / 深色和自定义主色、320pt 窄屏、俄文辅助功能大字体。
- `build/discover-social-review.xcresult`：加强后的大字体用例通过，滚动到社区卡片底部，确认下边界可见，再点击底部操作区域并验证目标页面。
- Debug 模拟器编译、Debug 真机签名编译、Release / iphoneos 编译通过。资源同步校验、工程文件解析、空白检查通过。
- 已安装并启动到 iPhone 15 Pro Max（iOS 27.0）；正常启动模式的真机截图确认发现页底部显示两张入口卡片。
- 已核对 Pixel 8 实机与 iOS 411.43pt 同宽预览。相同粉色主色下，卡片底色 `RGB(250,240,242)`、聊天室底色 `RGB(250,218,226)`、主色 `RGB(254,131,162)`、强调文字 `RGB(202,2,52)` 的截图采样一致。

```sh
python3 scripts/sync-discover-social-assets.py --check
xcodebuild -project Shaft-iOS.xcodeproj -scheme ReferralVerification \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/referral \
  -only-testing:Shaft-iOSUITests/DiscoverSocialUITests \
  CODE_SIGNING_ALLOWED=NO test
```

Debug 预览参数：`--discover-social-preview`；可追加 `--social-dark`、`--social-width=320`、`--social-large`、`--social-language=ru` 或 `--social-accent=FE83A2`。预览使用真实导航目标；Release 不启用预览入口。

## 截图

- [Android Pixel 8 基准](screenshots/android-pixel8-pink.png) / [iOS 411.43pt 同主色](screenshots/ios-411-pink.png)
- [iOS 浅色](screenshots/social-phone-light.png) / [深色](screenshots/social-phone-dark.png) / [320pt 窄屏](screenshots/social-320-light.png)
- [俄文大字体顶部](screenshots/social-320-russian-large-top.png) / [滚动至社区操作区域](screenshots/social-320-russian-large-bottom.png)
- [iPhone 15 Pro Max 发现页实机](screenshots/iphone15-pro-max-discover.png)
- [iPad 宽屏](screenshots/ipad-light.png)

对照采用 Android dp → iOS point。系统中文字体、文字抗锯齿、像素密度取整和系统安全区仍由各平台渲染；上述验收不是整屏零像素差异证明。

## 本轮 launch-review

标的为本会话尚未提交的发现页交流入口、路由、旧入口设置移除、资源及验证代码。Android 仅作只读对照；此前推介计划和其他会话改动不在本轮范围。

未发现需修复的新增崩溃或逻辑问题。明确检查了原生视图测量与双列等高、窄屏和长文案换行、动态字号、整卡点击与无障碍按钮语义、导航目标和返回、旧设置字段所有引用、资源加入 App target，以及 Debug 预览在 Release 中的隔离。

审查中加强了 `Shaft-iOSUITests/DiscoverSocialUITests.swift` 的大字体底部操作验证，并保存本记录；没有额外修改业务逻辑。广场提示页是已确认的本次范围，真实广场内容未实现；没有发送聊天消息或验证服务端聊天业务。
