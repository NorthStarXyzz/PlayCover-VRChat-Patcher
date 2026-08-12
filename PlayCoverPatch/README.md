# PlayCover VRChat customized-source patch

本目录保存针对 PlayCover upstream
`55638e98f36eac1f3d09803799480e9d83f663f8` 的有序、可审阅 patch series。
仓库不复制 PlayCover 的完整历史；新增 coordinator 作为 overlay 保存，其余源码改动
按顺序位于 `patches/`。

## 定制版身份与资料库

应用身份固定为：

```text
Bundle ID:    io.github.northstarxyzz.PlayCoverVRChat
Display name: PlayCover VRChat
App path:     /Applications/PlayCover VRChat.app
Library:      ~/Library/Containers/io.github.northstarxyzz.PlayCoverVRChat
```

它不会复用或迁移官方 PlayCover 的资料库。非 VRChat 应用若创建 alias，会使用独立的
`~/Applications/PlayCover VRChat/`；VRChat 完全禁用 alias，并从独立资料库中的真实
app URL 启动。定制版也不会调用 `PlayTools.installOnSystem()`，避免替换进程全局的
PlayTools framework。

官方 Sparkle 更新入口、feed、链接和嵌入仍被删除，避免官方更新覆盖定制源码。

## VRChat 的只读边界

普通 PlayCover IPA installer 会执行 Mach-O 转换、Info.plist 修改、注入和重签名，
因此定制版一旦在普通 install/export 流程识别到 `com.vrchat.mobile` 就立即拒绝。
VRChat 必须由 Patcher 事务导入为已经过受信 manifest 精确验证的兼容 app copy。

每次 VRChat 启动都固定执行以下只读检查：

- app URL 必须逐字节等于独立资料库中的
  `~/Library/Containers/io.github.northstarxyzz.PlayCoverVRChat/Applications/com.vrchat.mobile.app`，
  目录链和完整 bundle tree 都不能有 symlink；
- bundle ID、版本 `2026.2.30300 (1365)`、主可执行文件和 canonical
  entitlements digest 必须精确匹配；
- Security.framework strict code-signature 校验必须成功；
- 完整 bundle 必须恰好重现 46 个 reviewed thin-arm64 Mach-O 及
  `PCVR-MACHO-ALLOWLIST/1` aggregate digest，不能多一个或少一个；
- 主可执行文件的 UUID、normalized unsigned SHA-256 和 normalized load-command
  SHA-256 必须精确匹配 reviewed composite identity。

只要检查表示需要修复，启动就 fail-closed。该分支永不调用 `sign()`、
`Shell.signApp`、`Macho.convertMacho`、PlayTools inject/install 或任何 app-bundle
写操作。双击和所有内部 launch mode 都只能走 PCVR/2；定制版没有“标准启动
VRChat”菜单或隐藏 fallback。非 VRChat 仍使用 upstream 标准流程。

> 当前 source-only Alpha 没有完成 M5 实机验收，因此这里不声明任何候选
> patched-PlayCover payload 为受信身份。包含 payload 的 release 必须在另一个经过
> 审阅和实测的 manifest commit 中加入精确 hash/UUID。

## 动态内存设置

设置页提供两种模式：

- `automatic75Percent`：选择
  `floor(hw.memsize × 75% / GiB)`；
- `customGiB(UInt16)`：仅接受从 4 GiB 到当前安全上限的整 GiB。

非法值不会被 clamp。4–7 GiB 可以使用，但 UI 会明确警告可能出现 VRChat 功能或
资源加载受限。PlayCover 在启动开始时创建不可变 snapshot；运行中的设置改动只影响
下一次会话。即使自动模式也会把计算出的精确整 GiB 作为 runner 的唯一参数传入，
root controller 会根据当前 `hw.memsize` 再独立校验。

## Developer Alpha 授权

`DeveloperAlphaSystemAuthorizationProvider` 是可注入、可测试的临时 provider：

1. 只接受固定路径 `/usr/local/bin/playcover-vrchat-memory-policy`；
2. 用 `lstat` 验证 `/`、`/usr`、`/usr/local`、`/usr/local/bin` 和 runner 都不是 symlink，
   均由 root 拥有、没有 extended ACL、group/other write、append/immutable flag 或
   异常 link count，并验证 runner 是非空的 owner-executable regular file；
3. 以 `O_NOFOLLOW` 打开 runner，固定其 dev/inode/metadata 和完整 SHA-256；
4. 通过 macOS Authorization Services 请求系统管理员授权；
5. 在 legacy execute ABI 前后立即重开路径并与保留 fd 身份复核，不经 shell，只以
   唯一的 canonical ASCII decimal `<limitGiB>` 参数启动 runner。

它不打开 Terminal，不读取、传递或保存密码，也不调用 `Shell.runSu`。当前 SDK 把
旧 execute API 标为 Swift unavailable，因此 Alpha 在获得 execute right 后，从系统
Security framework 动态解析同名 ABI；符号不存在即 fail-closed。这是有意限定的
开发者 Alpha 过渡方案，不是公共发行架构。

`AuthorizationExecuteWithPrivileges` 只能接收 path，不能直接执行已验证 fd，因此最后
一次复核与系统 path lookup 之间仍有不可消除的竞态。Alpha 通过 root-owned 固定路径、
完整 runner hash 和执行前后复核缩小并检测窗口，但不宣称 descriptor-atomic。公共发行
必须换成带 code requirement 的签名 helper。

ACL 判定与 Darwin 语义保持一致：只有稳定对象上的 `acl_get_* == nil` 且
`errno == ENOENT` 表示没有 extended ACL；任何非空 `acl_t` 都表示 ACL 存在并立即
拒绝。测试会对真实临时文件调用 `acl_set_file`，再同时验证 path、descriptor getter
和 runner preflight，避免把 `acl_get_entry == 0` 的成功返回误判为空。

正式 `SMAppService` provider 在 v0.1 source-only Alpha 中明确不可用。只有在仓库
包含并审阅以下完整材料后才能启用：签名 embedded helper、launchd plist、固定 code
requirement、audit-token/XPC peer 校验、Developer ID 签名、公证和实机故障测试。
本 patch 不放置会“看似可用”但缺少这些边界的 skeleton。

## PCVR/2 contract

固定 socket：

```text
/private/var/run/io.github.northstarxyzz.pcvrpatcher/session.sock
```

固定 controller build ID：

```text
capability-vrchat-2026.2.30300-1365-r7
```

server 顺序：

```text
PCVR/2 HELLO <buildID>
PCVR/2 WAITING <selectedLimitMiB> <safeMaximumMiB>
PCVR/2 TARGET_BOUND <pid>
PCVR/2 LEASE_ACTIVE <pid> <selectedLimitMiB>
PCVR/2 METRICS <pid> <selectedLimitMiB> <footprintMiB.oneDecimal> <headroomMiB.oneDecimal> <reapplies> <pressure>
PCVR/2 COMPLETED
```

活动阶段可用 `PCVR/2 FAILED <stableCode>` 终止。client 唯一可发送的消息是绑定前
`PCVR/2 CANCEL`。client 校验 root peer、精确 build ID、WAITING 的 selected/safe
limit、PID、事件顺序以及每一条 lease/metrics 中的 selected limit。任何差异都作为
协议错误拒绝，不回退普通启动。

LaunchServices 返回后，定制 PlayCover 还会要求返回的 bundle URL、executable URL 和
正 PID 与刚才验证的副本一致，并把该 PID 与 controller 的第一条 `TARGET_BOUND` 精确
绑定。相同 bundle ID 的其他路径、错误 PID 或乱序事件都会关闭/合法取消 session，且
仅终止 LaunchServices 返回的那个 `NSRunningApplication`，不会进入普通启动。

## Patch 布局

1. `0001` 在 Xcode project 中登记 overlay coordinator。
2. `0002` 把 VRChat 排除在旧 PlayTools install/export 注入之外。
3. `0003` 接入旧的 coordinator 启动状态机。
4. `0004` 锁定 dependency bootstrap、禁用官方更新并加入补丁标识。
5. `0005` 从 target 移除 Sparkle package/link/embed/signing 路径。
6. `0006` 把上述过渡状态收敛为独立定制身份、只读 VRChat、无标准 fallback、
   PCVR/2 动态额度、系统授权 provider 与双语设置 UI。
7. `0007` 为包含空格的定制 product name 修正 PlayTools codesign build-phase 路径。
8. `0008` 把精确 reviewed bundle 身份、LaunchServices 返回进程和 controller
   `TARGET_BOUND` 绑定，并加入双语 fail-closed 错误。

`overlay/Cartfile.resolved` 固定 PlayTools commit
`f17b9211211fb4cf5652d4930ea82613ee3c92a5`。Xcode 26 的 PlayTools 兼容补丁与固定
SwiftPM resolution 位于 `dependencies/PlayTools/`；必须用其中的
`bootstrap-and-build.sh`，不得运行 `carthage update`。

## 图标集成点

已审阅的透明 runtime icon master 是：

```text
Design/Logo/playcover-vrchat-app-icon-v10.png
SHA-256 9962e1e2281a1c50f92a99df50937215707fb0a3f79895f0c1bd2c4046bf4719
```

本 patch series 没有把仓库外层的二进制设计资产复制进源码 patch。确定性 iconset
生成步骤应把该 master 输出为
`PlayCover/Assets.xcassets/PlayCoverVRChatAppIcon.appiconset/`，然后把两个 target
configuration 的 `ASSETCATALOG_COMPILER_APPICON_NAME` 改为
`PlayCoverVRChatAppIcon`。在生成脚本、所有尺寸 hash 和 Xcode 构建结果被一起审阅前，
不要以手工导出图片填充 patch。

## 检查与应用

先准备位于精确 upstream commit 且 `git status` 为空的 PlayCover clone：

```zsh
/bin/zsh PlayCoverPatch/check.sh --source /absolute/path/to/PlayCover
/bin/zsh PlayCoverPatch/apply.sh /absolute/path/to/PlayCover
/bin/zsh PlayCoverPatch/check.sh --applied /absolute/path/to/PlayCover
```

单独运行 coordinator、PCVR/2 parser、动态额度和依赖测试：

```zsh
/bin/zsh PlayCoverPatch/run-tests.sh
```

`check.sh --applied` 会重建 patch series 的期望 index，比较完整 tracked/untracked
provenance，执行 Swift parse/typecheck、plist/strings lint，并检查独立身份、只读入口、
无标准 VRChat launch、无 Terminal/password 路径、PCVR/2 和 dependency pin 不变量。
它不替代完整 Xcode build、签名/公证或 M5 真实 VRChat 验收。
