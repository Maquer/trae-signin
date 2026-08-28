# trae-signin — TRAE SOLO 纯签到工具

TRAE Work (SOLO CN) 的轻量签到工具。只做三件事：**登录 → 签到 → 查积分**，没有任何 OpenAI API 反代或对话功能。

基于 [traework2api](https://github.com/Sliverkiss/traework2api) 精简而来。

纯 Go 标准库，零第三方依赖。

## 功能

| 功能 | 说明 |
|------|------|
| **登录** | `login.sh` 生成登录链接 → 浏览器登录 → 粘贴回调 → 自动换 token 落盘 |
| **签到** | 批量遍历 `auths/` 下所有账号，自动刷新过期 token，逐个签到 |
| **积分查询** | 签到同时查询每个账号的积分余额 |
| **Bark 通知** | 签到完成后自动推送到 Bark（iOS 通知） |
| **定时签到** | 配合 Crontab / GitHub Actions 每天定时执行 |

## 快速开始

```bash
# 1. 安装依赖（需要 Go 1.21+ 和 Python 3）
# macOS: brew install go python3
# Ubuntu: apt install golang python3

# 2. 克隆仓库
git clone https://github.com/<your-username>/trae-signin.git
cd trae-signin
chmod +x login.sh signin.sh

# 3. 登录账号
./login.sh
# → 浏览器打开链接 → 手机号/验证码登录 → 粘贴回调链接

# 4. 签到
./signin.sh
# → 自动刷新 token → 签到 → 显示积分 → Bark 通知
```

> **Windows 用户**：无需 Python，直接用 PowerShell 运行 [login.ps1](login.ps1) 登录（详见下文「Windows 登录」），
> 签到用 Git Bash 执行 `./signin.sh` 即可。

## Bark 通知配置

签到完成后自动推送到 Bark。修改 `signin.sh` 中的 `BARK_URL`，或通过环境变量设置：

```bash
export BARK_URL="https://api.day.app/你的Key"
./signin.sh
```

推送内容示例：

> **✅ TRAE 签到成功**
> 总计1 | 成功1 | 已签0 | 失败0
> 弎水 ✅ OK 积分5100

## 定时签到

### 方式一：GitHub Actions（推荐）

最稳定的方案，不依赖本地环境，GitHub 服务器每天自动触发。

**配置步骤：**

1. Fork 或推送本仓库到你的 GitHub

2. 在仓库 Settings → Secrets and variables → Actions 中添加以下 Secrets：

   | Secret 名称 | 值 | 说明 |
   |---|---|---|
   | `TRAE_AUTH_1` | 账号1 的完整凭证 JSON | `auths/trae-*.json` 的文件内容 |
   | `TRAE_AUTH_2` | 账号2 的完整凭证 JSON | 同上，多个账号依次添加 |
   | `BARK_URL` | `https://api.day.app/你的Key` | Bark 推送地址 |

   只配置了几个 Secret 就只登录几个账号，未配置的会自动跳过。

3. 每天北京时间 08:00 自动执行，也可在 Actions 页面手动触发

> **注意**：如果是从他人仓库 **Fork** 来的，GitHub 默认会**禁用定时任务（schedule）**，
> 需要在你的 Fork 仓库 Settings → Actions → General 里勾选 "Allow GitHub Actions to create
> and approve pull requests" 旁边的 **"Enable workflows"**（或重新触发一次任意 workflow），
> 否则 `schedule` 永远不会执行、只会显示黄色感叹号。

> 凭证 JSON 格式（登录后从 `auths/trae-*.json` 复制）：
> ```json
> {"account":{"uid":"...","nickname":"..."},"auth":{"accessToken":"...","refreshToken":"...","expiresAt":1786858238,...}}
> ```

### 方式二：Crontab

```bash
# 每天 08:00 签到
crontab -e
# 添加：
0 8 * * * cd /path/to/trae-signin && bash signin.sh >> signin.log 2>&1
```

## Windows 登录

Windows 用户可用纯 PowerShell 脚本 [login.ps1](login.ps1) 登录，无需安装 Python：

```powershell
# 在项目目录下打开 PowerShell
powershell -ExecutionPolicy Bypass -File .\login.ps1
```

流程与 `login.sh` 一致：

1. 自动在默认浏览器打开登录链接，用手机号/验证码登录
2. 登录成功后浏览器跳到打不开的 `127.0.0.1` 地址
3. 复制地址栏完整链接，粘贴回 PowerShell（输入不回显）
4. 自动换取 Token 并保存到 `auths/trae-<uid>.json`，随后自动签到并显示积分

可选参数：

| 参数 | 说明 |
|------|------|
| `-NoOpen` | 不自动打开浏览器 |
| `-NoSignin` | 登录换 token 后不自动签到 |

登录完成后，用 Git Bash 运行 `./signin.sh`（或直接运行编译好的 `signin_bin.exe auths`）即可批量签到。

## 目录结构

```
cmd/
└── signin/main.go      签到入口（编译为 signin_bin / signin_bin.exe）

internal/
├── auth/auth.go        凭证文件解析与原子写回
└── upstream/upstream.go 上游 API 客户端（签到/积分/刷新 token）

login.sh                登录脚本（Linux / macOS / Git Bash）
login.ps1               登录脚本（Windows PowerShell，无需 Python）
signin.sh               签到脚本（含 Bark 通知）
crontab.txt             Crontab 配置参考
auths/                  （gitignored）凭证文件
```

## API 端点

本工具调用 TRAE 官方 API：

| 端点 | 用途 |
|------|------|
| `api.trae.com.cn/.../ExchangeToken` | 用 refreshToken 换 accessToken |
| `api.trae.cn/.../checkin_credits/status` | 查询签到状态 |
| `api.trae.cn/.../checkin_credits/claim` | 执行签到 |
| `api.trae.cn/.../ide_user_ent_usage` | 查询积分余额 |

## 安全说明

- 所有 token 仅保存在 `auths/` 目录（已 gitignored），不会上传到 Git
- 终端输出只显示 UID/昵称/积分，不打印 token
- `login.sh` 回调链接使用 `read -s` 不回显，避免终端留痕

## 致谢

- [traework2api](https://github.com/Sliverkiss/traework2api) — 原项目，本工具的精简来源
- [Bark](https://github.com/Finb/Bark) — iOS 通知推送工具

## License

MIT
