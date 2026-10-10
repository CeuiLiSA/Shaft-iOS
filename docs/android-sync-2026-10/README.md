# Android 近一周功能移植 · 2026-10-05～10

以 `Pixiv-Shaft/classic` 在 10 月 5～10 日的 79 个非合并提交为范围，对照 iOS 原有实现移植用户可见功能。Android 后续提交不自动进入本轮范围。

## 已接入

| 功能与上游提交 | iOS 实现与入口 |
|---|---|
| 应用锁 · `9dd6556a4` | 设置 → 账号。Face ID / Touch ID / 设备密码验证；冷启动锁定，后台返回按立即、1、5、15 分钟判断；非活跃时遮住页面。取消验证后保留手动解锁按钮，不重复自动弹窗。锁状态只保存在本机。 |
| 下载提示分类 · `91ff9d627` | 设置 → 下载 → 下载相关提示消息。控制已有的入列、批量入列、低存储、图片保存结果、小说导出进度与结果提示；旧总开关迁移一次，保留未知分类键。未实现的 Android 提示分类不显示空开关。 |
| 图片断流阈值与静默重试 · `05fde93e1`、`b88e2161f` | 设置 → 网络。普通连接默认 10 秒、直连默认 30 秒；可选更短阈值，重启生效。下载使用较短阈值时，收到字节后的读超时允许重试一次；图片显示的重试开关即时生效。标准连接优先使用系统 resume data，直连重新请求一次。 |
| 下载队列状态 · `68a4414d0`、`9f3ab50c8`、`540ac97d8`、`2870382e1` 等 | 不自动下载时入列即暂停；Wi-Fi 等待与手动暂停区分；单条继续仅放行本作品；全部继续与失败重试分开；切换下载模式即时重新判断。详情页按钮读取同一个队列，支持暂停、继续和重试。已存入相册的页数保留，避免重复保存。 |
| 字节进度与断流提示 · `6e372883b`、`d70d46340`、`8550ebf81` | 原图与动图 ZIP 共用传输进度。未知 Content-Length 不显示虚假的百分比；IO 时间戳驱动断流读秒；读到 EOF 后清除断流状态，编码和相册提交期间不会误报。取消一个订阅保留其他订阅，最后一个订阅退出才取消网络任务。 |
| 标题框选、保存当前图 · `92c09e8bf`、`e2525bae4` | 插画详情标题支持系统文本选择。大图页保留当前页保存与全部保存两种操作，当前页按钮使用图片保存语义和无障碍标签。 |
| 收藏、关注与滚动边缘反馈 · `fceec4ae9`、`75d84c4a8` | 插画收藏集中到交互仓库，小说详情、阅读器与关注入口补齐反馈；批量操作避免每条都震动。主要列表、作品详情、设置和纵向阅读器接入顶部 / 底部轻震，程序滚动与静态短页面不触发。 |
| 四种插画布局 · `7aaf13f0e` | 瀑布流、方格、齐行、单列；设置与卡片长按菜单共用带预览的选择器。所有原有插画网格与骨架屏跟随模式；齐行布局按实际比例计算，保留原生触控宽度。列表使用项目 ID 维护滚动位置。 |
| 卡片收藏按钮 · `ea2c9ac8f`、`e68e3bb2b` | 设置 → 外观。已显示的卡片也立即更新，关闭爱心后仍能通过详情页收藏。 |
| 首页官网 R-18 推荐 · `818ec49b9`、`2c9dbdc1e` | 插画与漫画首页补充官网推荐，按推荐 ID 顺序去重。要求网页会话属于当前账号、账号开启 R-18、全局过滤关闭；`me/state` 核验账号状态。补充请求限时 3 秒，失败退回原推荐流；数字年龄字段也参与本地过滤。 |
| 漫画横屏点击翻页与页码 · `46a3a4d0b`、`c590b2cb7` | 阅读器设置可关闭横屏点击翻页，保留点击显示控制栏；页码放在右上角，系统栏收起时保留避让位置，旋转时重算。 |
| AI 作者豁免启停 · `0c378f613`、`16aec3deb` | 设置 → 浏览 → 豁免作者。添加、删除、逐条启停；旧名单没有停用集合时全部启用。列表按有效豁免过滤；搜索只有不存在有效豁免时才向服务器请求直接排除 AI，其他情况在本地保留豁免作者。 |
| WebDAV 与本地备份 · `8f18cd4e7`、`9c46d3f43` | 设置 → 数据。配置、测试、手动备份、选择恢复、可选历史、后台自动检查，以及本地 gzip JSON 导出 / 导入。设备 UUID 区分所有权；每设备保留最新 10 份，不清理其他设备或没有所有权的旧备份。 |

新增文案复用 Android 的 7 种语言，平台差异在同步脚本中明确调整。字号、容器、主题色使用现有 iOS 组件；窄屏大字号下布局选择器与 WebDAV 操作改为纵向排布。

## 备份互通与边界

- 使用 Android 根字段与 gzip 格式，兼容旧时间戳文件名、纯 JSON 本地文件。gzip CRC、尾部、JSON 类型和版本全部检查完后才写入本机数据；输入及解压结果上限均为 128 MiB。
- 处理 56 个共同设置字段、屏蔽、搜索与置顶标签、浏览历史，以及可对应的下载策略。69 个 iOS 设置使用 `shaftIOS` 扩展；本机历史仍最多保留 500 项。
- iOS 暂无置顶作者页面：导入的 Android 作者数据保留在备份中，供再次导出使用。Android 路径模板、NAS / SAF 等下载配置保留用于回传，不在 iOS 上执行这些存储方式。iOS 下载落到相册。
- pixiv 登录账号、WebDAV 密码、应用锁状态不进入备份。Android AI key、aria2 密钥和设备迁移标记不会作为可恢复设置写入。WebDAV 密码和设备 UUID 放在 `ThisDeviceOnly` Keychain，服务器元数据文件排除系统备份。
- 手动与自动备份、远程与本地恢复共用可取消的串行入口。取消排队任务立即退出；取消恢复在主线程写入前再次检查。
- 自动备份每天检查一次，跳过内容未变的快照；需要非计费网络、非低电量模式，以及电量充足或正在充电。前台补检和 `BGProcessingTask` 共用流程。具体执行时刻由 iOS 调度，无法承诺精确每日时间，见 [Apple 后台任务文档](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest/requiresnetworkconnectivity)。
- 暂停后，未完成的图片可重新请求；已经保存的页不会重存。URLSession 读超时是否能续传取决于系统提供的 resume data，直连 HTTP/3 暂不承诺 Range 续传。
- 应用锁使用 [Apple 设备所有者验证策略](https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication)。真实设备的生物识别和系统后台调度仍需设备环境验证；本轮不接入个人云盘账号做上传实验。

## 无需或暂不适用的上游变化

| 上游变化 | 原因 |
|---|---|
| GitHub Releases Atom、APK 更新检查与限流提示 | iOS 没有 APK 更新链路，不引入 Android 安装器。 |
| AI 翻译原样度 / 二字组修正 | iOS 使用系统 Translation 面板，尚无 Android 自定义 AI 翻译请求与结果处理链路。 |
| AI 模糊粒子化下临时过滤 | iOS 尚无该模糊粒子化模式；本轮接入现有严格过滤及作者豁免。 |
| 二级大图评分快照、R8 keep | iOS 尚无对应评分与快照引擎，也不使用 R8。 |
| Fragment 1.8.9 / Android 10 insets 修复 | SwiftUI / UIKit 不存在该 FragmentContainerView 调用路径。 |
| ViewStub、DataBinding / ViewBinding、Glide、GLSurfaceView 性能提交 | 原生布局、图片管线和条件渲染不同；图片头本已使用静态字段，详情卡本已没有持续微光重绘。 |
| 下载记录 SQL 分批清理与 VACUUM | iOS 队列 / 完成记录使用串行原子 JSON 写入，没有该 SQLite 删除事务。 |
| 首次评论输入浮层、贴图描边、搜索主题色与临时提示布局 | iOS 使用已有的原生输入与贴图组件；搜索输入已使用语义正文色，没有对应 Android View 约束问题。 |
| 大图有翻译浮层时禁止拖动退出 | iOS 大图不提供该拖动退出与自定义翻译浮层组合。 |

## 验证

使用 Xcode 27、iOS 26.5 模拟器，最低部署版本保持 iOS 18。构建和测试命令：

```sh
xcodebuild -project Shaft-iOS.xcodeproj -scheme Shaft-iOS \
  -destination 'platform=iOS Simulator,id=00CC0FAD-5901-4EF6-B1AD-36095AF8EFA9' \
  -derivedDataPath /tmp/shaft-ios-october-port CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -only-testing:Shaft-iOSTests test
```

测试覆盖备份互通 / 完整性 / 凭据白名单 / 设备保留规则、锁屏前后台时限和取消、下载模式 / 页数恢复 / 过期任务回调、真实 URLSession 断流与取消、DAV XML / 重定向 / 上传字节，以及深浅主题、320pt 窄屏、俄文大字号和 768pt 平板宽度渲染。移植初验 141 项通过；上线前 review 补充 4 项回归测试后，完整测试为 **145 项通过，0 失败**，其中本轮新增 57 项。`test` 构建及 `git diff --check` 均通过；保留 17 张页面截图。

上线前 review 修正了四条具体路径：

- 应用锁原先只覆盖根页面，浮层和全屏阅读器仍可显示。改用独立观察锁状态的场景覆盖窗口，App 层接收前后台切换；单个场景非活跃时仍遮挡内容。覆盖窗口接收键盘焦点，原窗口的无障碍树暂时隐藏，解锁后恢复。回归检查 sheet / fullScreen、后台返回、解锁后保留原浮层，以及场景独立遮挡。
- 收藏后的自动下载和清晰度菜单只负责入列，普通下载按钮负责暂停 / 继续 / 重试，避免自动下载反而暂停已有任务。
- 动图在相册提交期间暂停，提交成功后仍记住完成页数；继续和重启只补完成记录，不重复编码和保存。
- 代理以 HTTP 200 返回错误页面时，解码失败会移除对应的坏缓存；下一次访问可重新请求。磁盘读写及条件失效在串行 actor 中执行，过期解码不会删除后来成功写入的字节。

截图保留于 [screenshots](screenshots)：[布局选择器](screenshots/layouts-390-light.png)、[俄文大字号布局](screenshots/layouts-320-russian-large.png)、[WebDAV](screenshots/webdav-390-dark.png)、[豁免启停](screenshots/ai-exempt-states-320-russian-large.png)、[应用锁](screenshots/lock-320-light.png)。

同步脚本分别负责 Android 文案、共同设置白名单和 Xcode 文件注册：

```sh
python3 scripts/sync-october-port-strings.py
python3 scripts/sync-backup-preferences.py
python3 scripts/register-october-port-files.py
```
