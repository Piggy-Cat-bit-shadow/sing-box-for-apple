# Jiejiebox Apple 客户端 — 施工基线记录（不可变引用）

> **本文件的用途**：记录本次架构重整开始前的所有原子引用、固定基线 SHA 与安全边界。
> 所有 SHA 都是执行 `git fetch` 之后从本机对象库实测得到的，不是从任务书或历史审计文档抄录的。
>
> **记录时间**：2026-10-10（本地，亚洲/上海时区）
> **记录者**：本次施工的 AI 代理（DeepSeek Harness）
> **施工分支**：`jiejiebox/integrated`（新建，未存在于施工前）

---

## 1. 远端（remotes）

| remote | URL | 权限 |
|---|---|---|
| `origin` | `https://github.com/Piggy-Cat-bit-shadow/sing-box-for-apple.git` | 用户 fork，可写（本次只推新分支） |
| `upstream` | `https://github.com/SagerNet/sing-box-for-apple.git` | 上游，**只读**（本次新建的跟踪 remote，仅 fetch，不推送） |

`upstream` remote 是在本次施工中新增的只读跟踪 remote，施工前本机不存在。新增 remote 不改变仓库内容。

## 2. 上游固定基线（唯一开发参考基线）

| 引用 | 完整 SHA | 提交时间 | 主题 |
|---|---|---|---|
| `upstream/dev` | `089d35e6b2a5f87e8fd1c0d5ceaba7eb82c8ce85` | 2026-10-09 12:35:26 +0800 | Bump version 1.15.0-alpha.11 |

**`upstream/dev` 是本次施工唯一采用的基线。** `upstream/main`（`e232aaf22d6d68773196ffc8e6e79684a6be717c`）与 `upstream/stable`
（`0b84ea472fbc9e1a7e11992b1f2daadbe2d30556`）不参与本轮合并。

集成分支从**这个固定 SHA** 建立，而不是从任何已有 Hako 分支复制仓库。

## 3. 施工前的 fork 分支（START_SHA，全部保持不动）

| 分支 | START_SHA（完整） | 提交时间 | 主题 |
|---|---|---|---|
| `dev`（fork 默认分支） | `d1224bb5081b3df5d0ecc55b1bd3d72ea6c60628` | 2026-10-02 19:25:25 +0800 | Bump version 1.15.0-alpha.10 |
| `hako-ui` | `c1935cff77246f97498400f5a0a7f430cfabbd55` | 2026-10-09 22:24:10 +0800 | feat(ui): the configuration row says how much quota is left |
| `ipad-upstream-ui` | `816600ab3f2823ab5de1da66e36433ef3a21fc10` | 2026-10-09 14:03:01 +0800 | test(apple): cover frozen UI guard failure cases |
| `fix/libbox-stringbox-callsites` | `2b23330d489b9f6b45e98f903f458842e8961594` | 2026-10-09 15:19:09 +0800 | fix(ui): install the screen-state observer the device axis needs |
| `fix/apple-notify-unknown` | `dd9114d9a20d1b252f20c4003f75e29974cb9c05` | 2026-10-09 21:10:25 +0800 | fix(apple): treat a failed notify read as unknown instead of unlocked |
| `main` | `ab33c3f083bb79928ef83c4fb96e9c7ac01bf3ba` | 2026-10-02 19:01:33 +0800 | Use the background color libghostty resolves for the terminal |
| `stable` | `0b84ea472fbc9e1a7e11992b1f2daadbe2d30556` | 2026-08-30 17:55:55 +0800 | Bump version 1.13.21 |

施工结束时这些 SHA 必须逐字不变。它们在本次施工中是**只读引用**：不 checkout、不 reset、不 rebase、不删除、不强推。

> 注意 `dev` 与 `origin/HEAD` 指向同一提交：fork 的**默认分支目前仍是 `dev`**。
> 本次施工**不切换 GitHub 默认分支**；README 中如实说明这一点。

## 4. 已有 tag（施工前存在，不得移动或覆盖）

| tag | 类型 | 指向 | 说明 |
|---|---|---|---|
| `iphone-hako-ui-freeze-v1` | annotated | tag 对象 `b7d830ea6ab2d21d2f2fc1d1e2fc2a6cf80d9503` → commit `fc7f77b82a7ca432294addfa001fcacfd5776223` | 历史冻结基线，**早于** `c1935cf` |
| `libbox-stringbox-abi-1` | lightweight | `8599039f6cd41dad6bdf975066b300725da08668` | libbox StringBox 调用点修复 1 |
| `libbox-stringbox-abi-2` | lightweight | `2b23330d489b9f6b45e98f903f458842e8961594` | libbox StringBox 调用点修复 2（= `fix/libbox-stringbox-callsites` 顶端） |

### 4.1 关于旧冻结基线的重要修正

任务书 §1.2 判断「旧冻结基线早于新的 UI 功能」，这个判断**经实测成立**：

- `fc7f77b`（freeze tag 指向的提交）的主题是 `feat(apple): port Hako subscription usage metadata`。
- `git merge-base --is-ancestor fc7f77b origin/hako-ui` 返回成功 → 它是 `hako-ui` 的祖先。
- `fc7f77b..origin/hako-ui` 只有 **2 个提交**：
  - `24bd463` `docs(apple): correct ownership inventory`（只加 `docs/HAKO-OWNERSHIP.md`）
  - `c1935cf` `feat(ui): the configuration row says how much quota is left`
    （`ProfilePickerSheet.swift` +142 / `Localizable.xcstrings` +16）

因此 **`c1935cf` 是旧冻结基线之后唯一的功能提交**，而它正好就是任务书点名不能丢失的「配置剩余流量显示」。
本轮的保护基线必须包含它，绝不能用 `fc7f77b` 作为验收期待值。

## 5. 差异矩阵（实测，非抄录）

`merge-base`、`rev-list --left-right --count` 全部在本机实测：

| A | B | merge-base | A 独有 | B 独有 |
|---|---|---|---|---|
| `upstream/dev` | `origin/hako-ui` | `2b1763a` | 53 | 82 |
| `upstream/dev` | `origin/ipad-upstream-ui` | `2b1763a` | 53 | 91 |
| `upstream/dev` | `origin/fix/libbox-stringbox-callsites` | `2b1763a` | 53 | 94 |
| `upstream/dev` | `origin/fix/apple-notify-unknown` | `3bcb8ca` | 29 | 20 |
| `upstream/dev` | `origin/dev`（fork） | `3bcb8ca` | 29 | 19 |
| `upstream/dev` | `origin/main` | `3bcb8ca` | 29 | 16 |
| `upstream/dev` | `origin/stable` | `0b84ea4` | 152 | 0 |

`2b1763a` = `Update App Store marketing versions`（2026-09-14）；
`3bcb8ca` = `Report main thread hangs as crash reports`（2026-09-06）。
`3bcb8ca` **不是** `2b1763a` 的祖先，且 `3bcb8ca..2b1763a` 之间的提交数为 **0** —— 说明
`2b1763a` 在 fork 分支上是一个被 rebase / 挑选过的提交，与上游同名提交不是同一个对象。

### 5.1 任务书 §1.1 的一处需要修正之处（FACT）

任务书表格里把 `hako-ui` 相对**fork `dev`** 记为 `ahead 82 / behind 43`，把 `ipad-upstream-ui`
记为 `ahead 91 / behind 43`。实测（相对 **`upstream/dev`**）是 **53 / 82** 和 **53 / 91**，
即任务书把「behind 53」写成了「behind 43」。这**不影响任何结论**：无论 43 还是 53，都不应机械合入。

更实质的一处修正在 §5.2。

### 5.2 `--cherry-pick` 复核：82 个 ahead 里有一批是「上游已有的等效提交」（FACT）

对 `upstream/dev...origin/hako-ui` 执行 `git log --left-right --cherry-pick`，
左侧（`<`，只在 `upstream/dev`）列出的 53 个提交中，有 **18 个的主题在 fork 侧存在等效实现**：

| 上游提交（`upstream/dev` 独有） | fork 侧等效提交 |
|---|---|
| `efcebc1` Use the background color libghostty resolves for the terminal | `ab33c3f`（fork `dev` 上同一主题） |
| `c0e575f` Fill terminal safe area with theme background | `0cc2a57` |
| `f4968f6` Forward Caps Lock to the input system in terminal | `4f94415`（上游后来 `69a0ee1` **Revert** 了它） |
| `58de956` Fix on-demand rule editor rows and domain rule validation | `e98364f` |
| `4443bce` Pause remote command clients in background instead of disconnecting | `0c49b8f` |
| `0ba5472` Improve on-demand rule editor | `b2ecd9e` |
| `31f54a8` Disable macOS terminal window restoration | `5d129ee` |
| `9fa67f5` Adapt terminal for iPad | `a1e78ca` |
| `d8c2282` Move remote control picker into menus when iPad sidebar is hidden | `8d01771` |
| `2d1da67` Remove remote control retries | `9bcd4c6` |
| `57ee030` Bump libghostty-spm | `dee60c0` |
| `a2143fc` Adapt layout for iPad | `3131ed6` |
| `33294f8` Show slashed menu bar icon when service is stopped | `e6e4f08` |
| `5c59c6d` Improve main thread hang diagnostics | `dc6fe12` |
| `89eacf7` Update dependencies | `ea89e88` |
| `4ffa778` Observe screen state in the extension | `f8ad6d0` |
| `60074f6` Pass process paths through helper XPC | `e3edd71` |
| `023cb8f` Add stub for platform auto redirect | `2070ae1` |

**结论**：这些改动**已经以同名不同 SHA 的形式存在于 fork 历史中**（fork 是从更新过的
`upstream/main` 或已 rebase 的分支上重建的）。它们**不需要重新 cherry-pick**，
也解释了为什么 `upstream/dev` 相对 fork 分支显示 53「独有」提交，而其中大部分内容并不缺失。

真正需要评估的上游新增内容，是**这 18 项之外**的提交，见
[`docs/APPLE-ARCHITECTURE-AUDIT.md`](APPLE-ARCHITECTURE-AUDIT.md)。

### 5.3 `ipad-upstream-ui` 是 `hako-ui` 的超集方向，不是平行方案（FACT）

实测 blob 大小（`git ls-tree -r -l`）：

| 文件 | `upstream/dev` | `hako-ui` | `ipad-upstream-ui` |
|---|---|---|---|
| `SFI/MainView.swift` | 21354 | 16093 | 21354（= 上游字节数） |
| `SFI/HakoPhoneRootView.swift` | 不存在 | 不存在 | 16394（新增） |
| `SFI/Application.swift` | 1115 | 1109 | 2777（设备分流） |
| `ApplicationLibrary/Views/HakoStyle/` | 不存在 | 11 文件 / 207623 字节 | 11 文件 / 208657 字节 |
| `ApplicationLibrary/Views/NavigationPage.swift` | 3369 | 4766（被改标题） | 3369（= 上游） |
| `ApplicationLibrary/Views/SidebarView.swift` | 8152 | 不存在（被删） | 8152（= 上游） |
| `ApplicationLibrary/Views/Abstract/SidebarLayout.swift` | 364 | 不存在（被删） | 364（= 上游） |
| `MacLibrary/MainView.swift` | 8674 | 12249 | 8674（= 上游） |
| `MacLibrary/SidebarView.swift` | 不存在（上游已删） | 8464 | 不存在 |
| `ApplicationLibrary/Views/Setting/SettingView.swift` | 8452 | 19983 | 19983（**仍被 Hako 改写**） |
| `ApplicationLibrary/Views/Tools/ToolsView.swift` | 18624 | 21535 | 21535（**仍被 Hako 改写**） |
| `ApplicationLibrary/Views/Dashboard/DashboardView.swift` | 5953 | 5021 | 5021（**仍被 Hako 改写**） |
| `ApplicationLibrary/Views/HakoStyle/HakoScaffold.swift` | 不存在 | 39468 | 39468 |

**证实的**：`ipad-upstream-ui` / `fix/libbox-stringbox-callsites` 确实恢复了
`SFI/MainView.swift`、`MacLibrary/MainView.swift`、`NavigationPage.swift`、`SidebarView.swift`
和 `SidebarLayout.swift` 的上游实现，并引入了正确的 `SFIUIFamily` 设备分流思路。

**同时证实的（任务书 §1.2 的核心判断成立）**：它**没有**解决共享页面的污染 ——
`SettingView`、`ToolsView`、`DashboardView` 在该分支上依然是 Hako 改写版，
所以 iPad 通过 `NavigationPage.contentView` 依旧会进入 Hako 呈现。
**「根视图文件恢复」不等于「整条页面调用链恢复」。**

### 5.4 Hako 类型名在共享文件中的分布（FACT，静态扫描）

对 `origin/hako-ui` 全树扫描 Hako 专属类型名（`HakoTheme` / `HakoRootScaffold` /
`HakoPageSection` / `HakoToolRow` / `HakoCard` / `HakoRow` / …）：

- Hako 自有文件（`/HakoStyle/` 下）：11 个。
- **Hako 自有文件之外引用 Hako 类型的文件：33 个**，包括
  `Setting/SettingView.swift`、`Tools/ToolsView.swift`、`Dashboard/DashboardView.swift`、
  `Connections/ConnectionListView.swift`、`Groups/GroupListView.swift`、`Log/LogView.swift`、
  `Dashboard/Cards/*`、`MacLibrary/MainView.swift`、`MacLibrary/SidebarView.swift`、`SFI/MainView.swift`。

这 33 个文件就是「污染面」。静态扫描的局限见审计报告的 `UNKNOWN` 章节。

## 6. 子模块

```
-baeb3cbf8332d26b4f7b4c175a01f288ebbf3e7f Frameworks/Runestone
```

`.gitmodules` 只有一项：`Frameworks/Runestone` → `https://github.com/nekohasekai/Runestone.git`。
该 gitlink 在 `upstream/dev`、`hako-ui`、`ipad-upstream-ui` 三个引用上**完全相同**，本轮不动。

## 7. GitHub Actions 触发面（实测）

**本仓库根目录不存在 `.github` 目录**，因此**仓库内没有 workflow 定义**。
这与任务书 §1.2 的记载一致。但依据任务书 §Phase E 的要求：

> 没有 workflow 文件**不等于**平台层面永远不会运行任何东西（组织级 / 仓库级 App、
> Dependabot、Code Scanning 等都可能独立配置）。

本轮**不主动触发任何 Actions**，也**不修改任何 workflow / 仓库设置**。

## 8. 施工用工作树（worktree）布局

施工在独立目录中进行，原有工作区不被 checkout / reset / clean：

| 目录 | 引用 | 用途 |
|---|---|---|
| `C:\Deepseek\IOS客户端\sing-box-for-apple` | `dev`（fork 默认分支） | 原始克隆，只读参考 |
| `C:\Deepseek\IOS客户端\_work\refs\up-hako` | detached @ `c1935cf` | `hako-ui` 只读参考 |
| `C:\Deepseek\IOS客户端\_work\refs\up-ipad` | detached @ `816600a` | `ipad-upstream-ui` 只读参考 |
| `C:\Deepseek\IOS客户端\_work\refs\up-libbox` | detached @ `2b23330` | libbox 修复只读参考 |
| `C:\Deepseek\IOS客户端\_work\refs\up-notify` | detached @ `dd9114d` | notify 修复只读参考 |
| `C:\Deepseek\IOS客户端\_work\refs\up-forkdev` | detached @ `d1224bb` | fork `dev` 只读参考 |
| `C:\Deepseek\IOS客户端\jiejiebox-integrated` | `jiejiebox/integrated` | **本轮唯一可写工作树**，基于 `upstream/dev` @ `089d35e` |

所有 `refs/up-*` 工作树都是 detached HEAD 的**只读参考**，不产生提交。

## 9. 本轮禁止事项（自缚约束，与任务书 §2 一致）

1. 不 `push --force` / `--force-with-lease`，不 rebase 共享分支，不删远端分支或 tag。
2. 不 checkout / reset / stash / clean 任何已存在的用户工作树。
3. 不更新父仓库 `Piggy-Cat-bit-shadow/sing-box` 的 `clients/apple` gitlink；不改父仓库 `testing` / `main`。
4. 不切换 GitHub 默认分支，不打正式 tag，不建 Release，不动签名 / 证书 / Bundle ID / App Group / VPN identifier。
5. 不改 `PRODUCT_NAME`、`Variant.applicationName`、extension 标识、Xcode scheme、构建产物路径。
6. 不做 tvOS 主动改造。
7. 不把补丁推给上游仓库（`upstream` 只 fetch）。
