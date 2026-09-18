# App 推介计划 · iOS 移植验收

入口：**更多 → App 推介计划**。邀请链接使用 `shaftintent://referral?code=…`；未登录时保存邀请码，登录后打开绑定确认。进入可绑定的推介页时，优先使用深链邀请码，否则检查剪贴板；每页只检查一次，每个账号记住最近 8 个已提示的剪贴板邀请码，自己的邀请码不提示。

## 基准与实现

基准为 `Pixiv-Shaft` 的 Android 原生页面，移植时参考提交 `1991008f8`，同时遵循 `docs/v3-design-philosophy.md`。Web 原型只用于核对设计意图。

| Android 源码 | iOS 对应 |
| --- | --- |
| `ReferralPageView.kt` | `ReferralPlanView.swift`：同页卡包、任务顺序、筛选、布局断点、留白 |
| `ReferralUi.kt` | `ReferralStyle.swift` / `ReferralIcons.swift`：页面配色、对比度校正、按钮、原始图标路径 |
| `ReferralHeroArtView.kt` | `ReferralArtCanvas`：428 × 370 画布、坐标、票孔、字体基线、−8° / +8° 旋转 |
| `ReferralPlanSheet.kt` | `ReferralSheet.swift`：任务、邀请、绑定、投稿、规则、领取和激活 |
| `ReferralModels.kt` / `ReferralRepository.kt` | `ReferralModels.swift` / `ReferralService.swift`：服务端状态与错误语义 |
| `strings_referral.xml`（七种语言） | `referral-strings.json`：自动生成，无手写翻译 |
| `witstudio/res/font/montserrat_*` | 完全相同的 400 / 500 / 600 / 700 / 800 字体文件 |

默认强调色使用 Android `AppTheme.colorPrimary` 的 **#686BDD**，没有采用旧 iOS 全局品牌色。深色与染色公式同源。原始 11 个图标转换为原生路径绘制；没有 WebView 或页面截图拼装。标题星号用原生绘制的行内符号，避免 iOS emoji 替换。

尺寸按 Android dp → iOS point、sp → 默认 point 对齐，字体随系统放大。窄屏会遵循 Android 的实际可用宽度规则：Hero 页边距与内边距扣除后，能容纳 `208 + 112 × fontScale` 才让操作与票卡并排。因此 402pt 与 411.43pt 手机可能分别展示上下、左右排列；不是按平台选择不同布局。760pt 起分栏，页面最大 1180pt，奖励栏 288pt。

底部弹窗自行绘制 30pt 顶角，避免系统浮动 Sheet 的额外边距。弹窗打开时阻止页面侧滑返回；超长内容滚动，输入与错误保留，提交禁重入，减少动态效果模式取消装饰缩放与入场位移。

## 数据与验证边界

正式页面请求 `https://pixshaft.com/v1/referral/*`，使用 Auth V2 Bearer；会话以现有 app HMAC 建立，不上传 Pixiv OAuth 凭据。轮换凭据及刷新重试 ID 存入 Keychain；明确失效后重建会话，断网或 5xx 保留原重试 ID。每次写入使用服务端返回的完整状态，409 后刷新；请求固定账号身份，账号切换后丢弃旧响应。登录账号进入前台时静默上报活跃日，收藏成功后另报收藏条件；两者按账号 / 上海自然日分别去重，活动关闭时不发信标。

Debug 的 `--referral-preview` 使用隔离测试数据，不调用线上领取、激活、绑定或投稿接口；Release 不包含该实现。**本次未用真实账号发放或消费奖励。**

## 自动检查

- Debug 模拟器编译与 Release 真机架构编译。
- 20 项单元测试：未知字段与状态、过期卡片、活动结束后的奖励、邀请码、动态规则与七语言、领取 / 激活状态替换、409 后刷新、账号切换与未登录；刷新凭据失效恢复、跨实例保留刷新重试 ID、区分非失效错误、并发刷新合并、缓存读取与 401 重试交错；活跃与收藏分别计数、上海零点跨日、失败重试及活动关闭；剪贴板提示资格、去重与历史上限、深链优先及待登录邀请持久化。
- 7 项界面测试：浅 / 深色、320pt、辅助功能大字体、俄文长文案；邀请复制与规则；领取 → 定位同页卡包 → 激活；活动结束后激活；投稿错误与审核补充说明；加载失败与重试；剪贴板提示去重 → 深链再次提示 → 绑定成功；补充推荐内容 → 提交成功 → 任务待审核。
- 字体、文案与图标资源同源校验，以及 `git diff --check`。

运行测试：

```sh
xcodebuild -project Shaft-iOS.xcodeproj -scheme ReferralVerification \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/referral CODE_SIGNING_ALLOWED=NO test
```

资源同步（需要 Python `fonttools`）：

```sh
python3 scripts/sync-referral-assets.py --check
python3 scripts/sync-referral-assets.py  # Android 资源有意更新后重新生成
```

稳定截图：构建 Debug 后，在已启动的 iPhone Pro Max 模拟器运行 `scripts/capture-referral.sh <UDID>`。界面测试另保存滚动位置与大字体截图。

## 截图

- [Android Pixel 8 浅色基准](screenshots/android-pixel8-light.png)
- [iOS 411.43pt 浅色](screenshots/phone-411-light.png) / [深色](screenshots/phone-411-dark.png)
- [iPhone 402pt 浅色](screenshots/phone-light-top.png) / [深色](screenshots/phone-dark-top.png)
- [320pt](screenshots/phone-320-top.png) / [大字体](screenshots/phone-320-large-top.png) / [俄文](screenshots/russian-320-top.png)
- [卡包](screenshots/claimed-wallet.png) / [任务](screenshots/phone-light-tasks.png)
- [邀请](screenshots/invite-sheet.png) / [规则](screenshots/rules-sheet.png) / [领取](screenshots/claim-sheet.png) / [激活](screenshots/activate-sheet.png) / [投稿](screenshots/submission-form.png)
- [iPad 浅色](screenshots/ipad-light.png) / [深色](screenshots/ipad-dark.png)

**对照限制：** Android 真机为 1080 × 2400 / 420dpi（411.43dp），iOS 截图来自 3× iPhone 与 2× iPad 模拟器。上述截图做了视觉和交互检查，不是零差异像素证明。系统状态栏 / 安全区、中文系统回退字体、文字抗锯齿、系统键盘与分享面板仍由各平台渲染，不能宣称整屏像素完全相同。

## 2026-09-18 上线前审查

标的为本会话未提交的 iOS 推介计划移植及其入口、网络调用、资源和测试。Android 与服务端只用于核对契约，没有修改。

已修两项：

1. `Shaft-iOS/Referral/ReferralService.swift:110`：刷新凭据过期、会话撤销或令牌重用检测返回 HTTP 400；原实现只对 401 重建会话，导致后续加载与奖励操作持续失败。现仅对 `invalid_grant` / `token_reuse_detected` 等明确失效结果重建会话；超时、5xx 和其他 400 保留轮换重试 ID。
2. `Shaft-iOS/ContentView.swift:26`、`Shaft-iOS/Referral/ReferralService.swift:310`：受邀人第二天回到 App、没有打开推介页也没有再次收藏时，原有旧签名在线接口不能提供服务端认可的活跃日证据，影响达标。现登录账号进入前台时发送 Bearer 活跃信标，收藏信标单独去重；失败释放占位，发送前复核账号。

确认过的路径包括：本人收藏成功才记收藏、借用账号不记入本人；领取与激活使用完整服务端快照；409 后补拉；账号切换丢弃旧响应；关闭活动后仍可处理已有奖励；深链经过登录后仍需确认绑定；弹窗提交期间防重复操作；字体、图标及七语言资源同源。

本轮校验：`ReferralVerification` 的 Debug 编译及 15 项单元测试、5 项界面测试全部通过（`build/referral-launch-review.xcresult`）；`Shaft-iOS` 的 Release / iphoneos 编译通过。资源同源检查、plist / 工程文件解析、截图脚本语法和空白检查通过。Release 仍有范围外 `Http3Client.swift` 的既有 Swift 6 并发兼容警告，本轮未修改该文件。

本轮修改文件：`Shaft-iOS/ContentView.swift`、`Shaft-iOS/Referral/ReferralService.swift`、`Shaft-iOSTests/ReferralTests.swift` 和本文档。审查修复随本次移植一同提交。认证与活跃测试均使用隔离 HTTP / 存储替身，不访问线上账号；真实奖励发放与消费仍未验证。

## 2026-09-18 第三轮审查

标的是本会话提交 `4ba916f`，重新对照 Android `1991008f8` 的入口、页面、弹窗、状态机与 Auth V2 刷新协调，以及服务端现有接口契约。Android 和服务端未修改。

已修两项：

1. `Shaft-iOS/Referral/ReferralPlanView.swift:387`、`Shaft-iOS/Referral/ReferralService.swift:380`：从邀请落地页复制邀请码后进入 iOS 推介页，原实现只读取深链参数，漏掉 Android 的剪贴板绑定确认入口。现补齐深链优先、本人码过滤、可绑定状态检查、每页一次及按账号保存最近 8 个提示码；关闭其他弹窗后再检查，避免覆盖当前操作。
2. `Shaft-iOS/Referral/ReferralService.swift:44`：普通请求读取缓存凭据时，401 重试可能加入同一个异步任务，拿回刚被拒绝的旧凭据，耗尽唯一重试机会。并发回归测试已在修复前复现。现同步完成缓存读取，只合并真正的凭据刷新 / 建立请求，保留轮换重试 ID 的持久化语义。

闭环检查包括：未登录邀请保留至登录后确认；绑定后页脚移除入口；投稿失败保留输入、补充成功进入待审核；领取后同页卡包可激活；活动结束仍保留已有奖励；409 后重载；账号切换丢弃旧响应；前台活跃和收藏分别上报。UI 测试使用隔离数据，认证测试使用 HTTP / 存储替身；没有向线上发放或消费奖励。

验证证据：

- `build/referral-review3-initial.xcresult`：剪贴板修复后的 Debug 编译、19 项单元测试及 7 项界面测试通过。
- `build/referral-review3-auth-repro.xcresult`：新增并发回归用例在鉴权修复前失败，确认会返回已拒绝的 token。
- `build/referral-review3-auth-fixed.xcresult`：鉴权修复后的 Debug 编译及全部 20 项单元测试通过。鉴权调整不改变使用隔离服务的 UI 测试路径。
- Release / iphoneos 编译通过；11 个图标、7 种语言、5 档字体同源检查及 `git diff --check` 通过。构建日志仍有范围外的既有弃用与 Swift 6 并发兼容警告。
- 按用户要求完成 iPhone 15 Pro Max（iOS 27.0）的 Debug 签名编译、安装和正常启动；通过设备进程查询与截图确认首页已显示。真机未使用预览启动参数，未执行领取、激活或绑定操作。

本轮修改：`ReferralService.swift`、`ReferralPlanView.swift`、`ReferralPreview.swift`、`ReferralTests.swift`、`ReferralUITests.swift` 和本文档；修复以新提交叠加到 `main`。
