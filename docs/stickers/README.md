# iOS Sticker 系统

按 Pixiv-Shaft 当前 `ceui.pixiv.sticker`、聊天和广场源码移植。生产代码位于 `Shaft-iOS/Sticker/`，共享仓库、选择器和本地图像组件；原 `PlazaStickers.swift` 仅保留兼容入口。

## 两条业务链路

| 入口 | 选择贴纸后的行为 | 展示 |
| --- | --- | --- |
| `ChatThreadView` 输入栏 | 公屏 / 私信通过 WS 发送 `[贴纸]` 和十进制字符串 `sticker_id`；保持面板展开、保留文本草稿 | 64pt 无气泡图像，读取本地 128 档，时间和失败状态放在图像旁 |
| `PlazaPostView` 回应按钮 | Sheet 选中后关闭，调用 `PUT …/reactions/stickers/{id}`；已选回应通过 `DELETE` 取消 | 18pt 回应图像，读取本地 64 档，计数与选中态沿用广场 |
| `PlazaDetailView` 输入栏 | 内嵌选择器回应当前父帖子，选择后保持展开；文本仍按原评论流程发送 | 与聊天室相同的选择器与键盘切换 |

聊天室乐观消息、WS 回声、历史接口和 JSON 本地保存均保留 `stickerId`。旧消息不带字段仍可读取。Pixiv 作品评论不接入这套系统。

## 视觉与交互

以 Android **当前源码**为准：分类在左，Sheet 的关闭按钮在右，无标题。英文及数字使用项目已有 Montserrat 真实字重，中文使用系统回退。

| 元素 | 默认尺寸 |
| --- | --- |
| Sheet / 内嵌顶栏 | 56 / 48pt |
| 分类热区 / 轨道 / 选中块 | 48 / 42 / 36pt |
| 轨道 / 选中块圆角 | 14 / 11pt |
| 分类字号 / 最小宽度 / 水平留白 | 13pt Medium / 64pt / 16pt |
| 网格外边距 | 左右 12、上 12、下 8pt |
| 格子 / 图像内边距 | 48pt 高 / 8pt，列数 `clamp(floor((宽度−24)/48),3,12)` |
| Sheet 最大内容宽度 / 标准高度 / 顶角 | 640 / 420 / 28pt |
| 内嵌面板 | 跟随键盘高度，首次默认 270pt |

分类点按与横向分页使用同一状态，滑块连续跟随拖动和回退；各页独立保留纵向位置，重复点击当前分类不刷新。Sheet 网格自身承接底部安全区；内嵌模式由宿主管理。隐藏或离屏停止解码，减少动态效果和后台状态下显示静态首帧。

大字号长分类超出剩余行宽时，将关闭按钮和分类分成两行，保持完整文案可达；普通字号保留 Android 的同排布局。主题色由宿主传入：聊天室跟随 iOS 聊天主色，广场跟随 `PlazaPalette`，不新增固定主题。浅色 / 深色强调文字按 HSL 和实际背景对比度校正。

这次核对的是组件尺寸、资源、颜色关系与交互；系统中文字体、键盘、系统 Sheet 与截图像素密度仍由 iOS 控制，不把跨平台整屏像素差为零作为结论。

## 安装、校验和离线

元数据来自 Tokyo `https://api.pixshaft.com/f/v1/stickers-version` 和 `stickers?type=customized|static|animation`。ZIP 只允许指定 COS `/public/stickers/` 地址，独立无凭证 URLSession 禁止重定向。资源 URL 只用来匹配包内路径，不作为图片网络请求。

保存到 `Application Support/stickers` 并排除系统备份，不使用可清理的图片缓存目录：

```text
catalog.json
ready.json
packages/<SHA-256>/archive.zip
packages/<SHA-256>/downloaded.json
packages/<SHA-256>/extracted.json
packages/<SHA-256>/files/...
```

四份 ZIP 全部通过长度 / SHA-256、逐文件 CRC、路径、条目数及解压量限制后才开放总就绪状态。拒绝目录穿越、绝对路径、符号链接、加密与未知压缩方法；逐文件解压，保留 ZIP 供修复复用。写入总标记之前验证全部解压记录及所有被引用的 64/128 档文件。

已有安装可离线重开；入口检查真实文件大小、修改时间和文件编号，不复用 Foundation 的 URL 属性缓存。首个版本检查发现更新时换代安装；联网失败保留已有完整资源。应用内只有一个安装任务，关闭选择器不取消下载；进程中断后重新验证，复用完成包。

ImageIO 读取真实 WebP/GIF/APNG 帧时长。只解码可见图像的当前帧，帧缓存上限 24MiB；没有 100 帧截断，也不一次展开整套动画。解码失败只能关闭对应 generation 的就绪状态，旧请求不会覆盖新版本。

## 验证

2026-09-18：iPhone 17 Pro / iOS Simulator 26.5，最终 **37/37 通过，0 失败、0 跳过**（14 项 sticker 逻辑测试、2 项渲染与交互测试、21 项广场回归测试），结果包 `/tmp/shaft-sticker-verified.xcresult`。`git diff --check` 通过。另通过实际 URLSession 从 Tokyo / COS 完成四包下载与安装，得到 2,159 个贴纸；再次准备复用同一 generation。

`StickerTests` 覆盖 64 位 ID、旧历史兼容、post 回应 PUT/DELETE 路由、共享包去重、路径越界、CRC、截断 ZIP、部分安装门禁、离线重开、资源缺失 / 同长度损坏修复、真实 WebP 多帧及七语言文案。

`StickerRenderTests` 验证分段和网格尺寸、拖动中间位置及取消回退、分类滚动位置、选择回调和重复点按，并输出手机 / 平板、深浅主题、320 宽俄语大字号、内嵌面板、加载 / 失败和聊天消息截图。

```sh
python3 scripts/register-sticker-files.py
xcodebuild -project Shaft-iOS.xcodeproj -scheme Shaft-iOS \
  -destination 'platform=iOS Simulator,name=Shaft Sticker Validation' \
  -derivedDataPath /tmp/shaft-sticker-build \
  -only-testing:Shaft-iOSTests/StickerTests \
  -only-testing:Shaft-iOSTests/StickerRenderTests \
  -only-testing:Shaft-iOSTests/PlazaTests \
  -skip-testing:Shaft-iOSUITests -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
```

测试夹具从同一官方目录 / COS ZIP 提取：精选与表情各前 64 个、动态前 12 个；重新封装并计算独立 SHA-256，不用于生产目录。完整线上四包另在 `/tmp/shaft-sticker-assets` 校验，新存储层实际安装了 2,159 个贴纸、15,928 个文件 / 标记，包含 64/128 两档。

[浅色选择器](screenshots/picker-390-light.png) · [深色选择器](screenshots/picker-390-dark.png) · [大字号俄语](screenshots/picker-320-large-russian.png) · [聊天贴纸](screenshots/chat-stickers-dark.png) · [全部截图](screenshots/)

验证不会向公屏或线上帖子发送测试内容；发包与回应协议通过本地捕获请求验证。
