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
| **定时签到** | 内置调度器，每天定时执行 |

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

### 方式一：内置调度器

```bash
go build -o scheduler ./cmd/scheduler
./scheduler &
# → 每天 08:00 自动签到
```

### 方式二：Crontab

```bash
# 每天 08:00 签到
crontab -e
# 添加：
0 8 * * * cd /path/to/trae-signin && bash signin.sh >> signin.log 2>&1
```

## 目录结构

```
cmd/
├── signin/main.go      签到入口
└── scheduler/main.go   定时调度器

internal/
├── auth/auth.go        凭证文件解析与原子写回
└── upstream/upstream.go 上游 API 客户端（签到/积分/刷新 token）

login.sh                登录脚本
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
