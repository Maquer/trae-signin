# trae-signin — TRAE SOLO 纯签到工具

TRAE Work (SOLO CN) 的轻量签到工具。只做三件事：**登录 → 签到 → 查积分**，没有任何 OpenAI API 反代或对话功能。

基于 [traework2api](https://github.com/Sliverkiss/traework2api) 精简而来。

纯 Go 标准库，零第三方依赖。

## 功能

| 功能 | 说明 |
|------|------|
| **登录** | `login.sh` 生成登录链接 → 浏览器登录 → 粘贴回调 → 自动换 token 落盘 |
| **签到** | 批量遍历 `auths/` 下所有账号，自动刷新过期 token，逐个签到 |
| **到账校验** | 签到后回查确认，接口返回成功但积分未到账会标记为 `UNCONFIRMED`（不谎报成功） |
| **积分拆分** | 分别显示「月赠额度」与「签到奖励额度」，一眼看出签到有没有加分 |
| **Bark 通知** | 签到完成后自动推送到 Bark（iOS 通知） |
| **定时签到** | GitHub Actions 每天定时执行 |

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

签到完成后自动推送到 Bark。通过环境变量设置（**不要把真实 Key 写进仓库**）：

```bash
export BARK_URL="https://api.day.app/你的Key"
./signin.sh
```

推送内容示例：

> **✅ TRAE 签到成功**
> 总计2 | 成功1 | 已签1 | 未确认0 | 失败0
> 弎水 ALREADY 总600(签到+100)
> 用户0670362 ✅ OK 总600(签到+100)

> **⚠️ TRAE 签到未确认**
> 总计2 | 成功0 | 已签1 | 未确认1 | 失败0
> 弎水 ALREADY 总600(签到+100)
> 用户0670362 UNCONFIRMED 总500(签到0)

## 签到状态说明

| 状态 | 含义 |
|---|---|
| `✅ OK` | 签到成功，且已回查确认积分到账 |
| `ALREADY` | 今日已签到，无需重复 |
| `UNCONFIRMED` | 签到接口返回成功，但回查发现积分未到账（通常为服务端风控静默拦截），**不计为失败但会告警** |
| `DISABLED` | 账号被服务端禁用签到，不计为失败 |
| `FAIL` | 网络错误、HTTP 4xx/5xx 或 token 刷新失败 |

> 回查机制的意义：TRAE 的 `claim` 接口在风控拦截时仍可能返回 HTTP 200，但 `checked_in` 不会翻转、积分也不会到账。本工具会重新查询状态与积分包，只有确认到账才判为成功，避免"假成功"。

## 积分构成说明

TRAE 的积分由**多个独立到期的包**组成，`总计` 是它们的合计：

| 包 | 来源 | 有效期 |
|---|---|---|
| 每月登录赠送 | 每月自动发放（通常 500） | 按自然月 |
| 签到奖励 | 每日签到发放（100/天） | 自签到日起 31 天 |

所以「签到成功但总积分没涨」的常见原因是：**签到包是独立的一份，且会单独过期**。本工具已把两项拆开显示在 `月赠` / `签到` 两列。

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

3. 每天北京时间 08:00 自动执行，也可在 Actions 页面手动触发

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

## 目录结构

```
cmd/
└── signin/main.go      签到入口

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
