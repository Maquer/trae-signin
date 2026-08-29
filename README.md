# trae-signin — TRAE 每日签到工具

TRAE (SOLO CN) 的轻量签到工具。只做三件事：**登录 → 签到 → 查积分**，没有任何 OpenAI API 反代或对话功能。

基于 [traework2api](https://github.com/Sliverkiss/traework2api) 精简而来。纯 Go 标准库，零第三方依赖。

---

## ⚠️ 重要：签到绑定设备（先读这里）

**TRAE 的每日签到是绑定设备的**。官方签到入口只在 **TraeWork 桌面端（Windows）**，服务端会用请求里的 `x-device-id` 校验「设备 ↔ 账号」的绑定关系：

- 使用**正确绑定设备 ID** → 签到成功，到账 200 Work 专属积分
- 使用**错误/随机设备 ID** → 服务端返回 `9074 当前参与用户太多`（实为设备校验失败的模糊提示），**积分不会到账**

这正是很多用户「显示签到成功但积分不涨」的根因：
1. 旧版本脚本不检查响应体里的 `code` 字段，把 `9074` 这类失败误报成「✅ 签到成功」；
2. 凭证里的 `deviceId` 是登录时随机生成的，与账号绑定的真实设备不一致。

本项目已修复以上问题（见 [更新记录](#更新记录)）。**Windows 用户用本工具可直接正常签到**；Linux / macOS / GitHub Actions 的可行性见下文「[平台支持](#平台支持)」。

---

## 积分体系

TRAE 积分分两种（同一账号共享额度，但**签到发的只能用在 TraeWork**）：

| 类型 | 适用范围 | 每日签到 |
|------|---------|---------|
| **通用积分** | TraeCode + TraeWork | ✗ |
| **Work 专属积分** | 仅 TraeWork | ✅ 每天 200，月上限 6200 |

因此签到后，**IDE（TraeCode）里的积分不会涨**，要看 Work 专属积分（本工具会在结果里单独显示「签到奖励」累计值）。

---

## 平台支持

| 平台 | 能否签到 | 说明 |
|------|---------|------|
| **Windows** | ✅ 推荐 | 安装 TraeWork 桌面端登录一次即绑定设备；`login.ps1` 会自动读取本机真实设备 ID 写入凭证 |
| **macOS** | ❌ 直接不能 | TraeWork **没有 macOS 桌面端**，无法在本地完成设备绑定 |
| **Linux** | ❌ 直接不能 | 同上，没有 Linux 桌面端 |
| **GitHub Actions** | ⚠️ 看凭证 | runner 是 Linux，但**只要 Secret 凭证里的 deviceId 是已绑定的设备 ID**，理论上可签到（建议实测确认） |

> **结论**：纯 Linux / macOS 环境**无法直接使用 Work 签到**，因为签到入口（TraeWork 桌面端）只有 Windows 版，设备绑定这一步绕不过去。
> 变通方案见下文「[Linux / macOS 用户](#linux--macos-用户)」。

---

## 功能

| 功能 | 说明 |
|------|------|
| **登录** | `login.sh` / `login.ps1` 生成登录链接 → 浏览器登录 → 粘贴回调 → 自动换 token 落盘 |
| **签到** | 批量遍历 `auths/` 下所有账号，自动刷新过期 token，逐个签到（带限流重试） |
| **积分查询** | 签到同时查询总剩余 + **累计签到奖励**（Work 专属积分） |
| **Bark 通知** | 签到完成后自动推送 Bark（iOS 通知），含签到奖励信息 |
| **定时签到** | 配合 Crontab / GitHub Actions 每天定时执行 |

---

## 快速开始

### Windows（推荐）

```powershell
# 1. 安装并登录一次 TraeWork 桌面端（重要：用于绑定设备）
#    下载: https://www.trae.cn 首页右下角

# 2. 打开 PowerShell，进入项目目录，登录账号
powershell -ExecutionPolicy Bypass -File .\login.ps1
#   - 自动打开浏览器 → 手机号/验证码登录 → 复制回调链接粘贴回终端
#   - 会自动读取本机 TRAE SOLO CN 的真实设备 ID 写入凭证

# 3. 用 Git Bash 签到（或在项目目录直接运行编译好的二进制）
./signin.sh
#   或: go build -o signin_bin.exe ./cmd/signin && .\signin_bin.exe auths
```

### Linux / macOS

```bash
# 1. 依赖: Go 1.21+、Python 3
#    macOS: brew install go python3
#    Ubuntu: apt install golang python3

# 2. 登录（注意: 仅登录换 token 可用，签到受设备绑定限制，见下）
chmod +x login.sh signin.sh
./login.sh
```

**Linux / macOS 签到限制**：TRAE 没有这两平台的桌面端，`login.sh` 读不到绑定设备 ID，生成的凭证里 deviceId 是随机的 → 直接 `./signin.sh` 会因设备校验失败（9074）。详见「[Linux / macOS 用户](#linux--macos-用户)」。

---

## Linux / macOS 用户

由于 TraeWork 无 Linux / macOS 桌面端，**你无法在本机完成签到所需的设备绑定**。可用的替代路径：

### 方案 A：借用一台 Windows 机器绑定设备（推荐）

1. 在任意一台 **Windows** 电脑上安装 TraeWork 桌面端，登录你的账号（完成设备绑定）；
2. 打开 `%APPDATA%\TRAE SOLO CN\ModularData\ckg_server\local_env.json`，记下 `device_id`（如 `2701955725849561`）；
3. 在你的 Linux / macOS 上运行 `./login.sh` 生成凭证后，把 `auths/trae-*.json` 里 `auth.deviceId` 替换为上面的真实 `device_id`；
4. 之后 `./signin.sh` 即可正常签到——**服务端校验的是 device_id 与账号的绑定关系，不校验请求来源平台**（已实测）。

> 同样适用于 **GitHub Actions**：把含真实 device_id 的凭证放进 Secret，runner 上即可签到。

### 方案 B：Windows 机器上直接跑（最简单）

如果 Windows 机器能保持运行，直接在那台机器上按「快速开始 - Windows」跑，配合计划任务每天定时签到即可。

### 风险提示

- 借用/共享的 Windows 设备若长期不活跃，账号可能被风控，**请自担风险**；
- 服务端策略可能随时变化（例如未来增加「设备在线」校验），届时纯 API 签到可能失效；
- 同一台设备一天只能签一个账号（官方规则）。

---

## Bark 通知配置

```bash
export BARK_URL="https://api.day.app/你的Key"
./signin.sh
```

推送内容示例：

> **✅ TRAE 签到成功**
> 总计1 | 成功1 | 已签0 | 失败0 | 签到奖励1800 | 总剩余5626

---

## 定时签到

### 方式一：GitHub Actions（推荐）

1. Fork 或推送本仓库到你的 GitHub；
2. Settings → Secrets and variables → Actions 添加：

   | Secret | 值 | 说明 |
   |---|---|---|
   | `TRAE_AUTH_1` | 账号1 完整凭证 JSON | `auths/trae-*.json` 文件内容（**必须含已绑定设备的 deviceId**） |
   | `TRAE_AUTH_2` | 账号2 完整凭证 JSON | 多个账号依次添加 |
   | `BARK_URL` | `https://api.day.app/你的Key` | 可选，Bark 推送 |

3. 每天北京时间 08:00 自动执行，也可在 Actions 页手动触发。

> ⚠️ **Fork 来的仓库**：GitHub 默认禁用定时任务，需在 Actions 页启用 Workflows。
> ⚠️ **签到受设备绑定限制**：若 Secret 凭证里的 deviceId 是随机值，Actions 中签到会失败（9074）。
> 必须使用从 Windows 绑定设备导出的凭证。

### 方式二：Crontab（适合 Windows 之外的机器）

```bash
crontab -e
# 每天 08:00 签到
0 8 * * * cd /path/to/trae-signin && bash signin.sh >> signin.log 2>&1
```

---

## 目录结构

```
cmd/
└── signin/main.go       签到入口（编译为 signin_bin / signin_bin.exe）

internal/
├── auth/auth.go         凭证解析与原子写回
└── upstream/upstream.go 上游 API（签到/积分/刷新 token，含业务错误码校验）

login.sh                 登录脚本（Linux / macOS / Git Bash，自动读取本机绑定设备 ID）
login.ps1                登录脚本（Windows PowerShell，无需 Python，自动读取本机绑定设备 ID）
signin.sh                签到脚本（含 Bark 通知）
crontab.txt              Crontab 配置参考
auths/                   （gitignored）凭证文件
```

## API 端点

| 端点 | 用途 |
|------|------|
| `api.trae.com.cn/.../ExchangeToken` | 用 refreshToken 换 accessToken |
| `api.trae.cn/.../checkin_credits/status` | 查询签到状态 |
| `api.trae.cn/.../checkin_credits/claim` | 执行签到（**绑定设备**，需正确 `x-device-id`） |
| `api.trae.cn/.../ide_user_ent_usage` | 查询积分余额（含累计签到奖励） |

## 常见问题

**Q：显示「签到成功」但积分不涨？**
旧版本会误报成功（未校验响应 body 的 `code`）。更新到最新版本后，失败会如实显示错误码（如 9074）。若仍失败，99% 是 deviceId 未绑定真实设备。

**Q：报 `9074 当前参与用户太多`？**
真实原因通常是 **deviceId 未绑定**（或已绑定设备当日已签过）。用 Windows 桌面端绑定设备后重新生成凭证即可。

**Q：为什么「积分」数字在下降？**
那是**通用积分**（被 TraeCode/Work 使用消耗）。签到发的 Work 专属积分看「签到奖励」列，它每天 +200 递增。

**Q：一台电脑能签几个账号？**
官方：一台设备一天只能签一个 TRAE 账号。

## 安全说明

- 所有 token 仅保存在 `auths/`（已 gitignored），不会上传到 Git；
- 终端输出只显示 UID/昵称/积分，不打印 token；
- `login.sh` / `login.ps1` 回调链接输入不回显。

## 更新记录

- 修复签到被设备绑定拒绝时误报成功（校验响应 `code` 字段）；
- 修复积分计算（改用权威 `usage_summary`，并单独展示「签到奖励」累计）；
- `login.ps1` / `login.sh` 登录时自动读取本机 TRAE 桌面端的真实设备 ID；
- 签到遇限流自动重试。

## 致谢

- [traework2api](https://github.com/Sliverkiss/traework2api) — 原项目，本工具的精简来源
- [Bark](https://github.com/Finb/Bark) — iOS 通知推送工具

## License

MIT
