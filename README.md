# trae-signin — TRAE 每日签到工具

TRAE (SOLO CN) 轻量签到工具：**登录 → 签到 → 查积分**，纯 Go 标准库，零依赖。基于 [traework2api](https://github.com/Sliverkiss/traework2api) 精简而来。

---

## ⚠️ 先读：签到绑定设备

TRAE 每日签到**绑定设备**。官方签到入口只在 **TraeWork 桌面端（Windows）**，服务端校验请求里的 `x-device-id` 与账号的绑定关系：

- 绑定设备 ID → 签到成功，到账 **200 Work 专属积分/天**
- 随机/错误设备 ID → 返回 `9074 参与用户太多`（实为设备校验失败的模糊提示），**积分不到账**

常见误区：旧版本脚本不检查响应体 `code` 字段，把 9074 误报成「✅ 签到成功」→「显示成功但积分不涨」。本项目已修复。

---

## 积分体系

| 类型 | 适用范围 | 每日签到 |
|------|---------|---------|
| 通用积分 | TraeCode + TraeWork | ✗ |
| **Work 专属积分** | 仅 TraeWork | ✅ 200/天，月上限 6200 |

签到发的是 **Work 专属积分**，IDE（TraeCode）里的积分不会因签到而涨。本工具单独显示「签到奖励」累计值。

## 平台支持

| 平台 | 能否签到 | 说明 |
|------|---------|------|
| Windows | ✅ | 桌面端登录一次即绑定设备，`login.ps1` 复用该设备 ID |
| macOS / Linux | ❌ | 无桌面端，无法本地绑定设备 |
| GitHub Actions | ⚠️ 视凭证 | runner 是 Linux，但凭证含已绑定设备 ID 即可签（建议实测） |

---

## 快速开始

### Windows（推荐）

```powershell
# 1. 先安装 TraeWork 桌面端并用目标账号登录一次（完成设备绑定）
#    下载: https://www.trae.cn 首页右下角
# 2. 登录生成凭证（自动复用桌面端绑定的设备 ID）
powershell -ExecutionPolicy Bypass -File .\login.ps1
# 3. 签到
./signin.sh   # 或 go build -o signin_bin.exe ./cmd/signin && .\signin_bin.exe auths
```

### Linux / macOS

```bash
chmod +x login.sh signin.sh
./login.sh   # 仅登录可用；签到受设备绑定限制，见「Linux / macOS 用户」
```

---

## Linux / macOS 用户

无桌面端 → 无法本机绑定设备 → **不能直接签到**。替代路径：

**方案 A（推荐）：借一台 Windows 机器绑定**
1. 在 Windows 装 TraeWork 桌面端，登录你的账号（完成绑定）
2. 打开 `%APPDATA%\TRAE SOLO CN\ModularData\ckg_server\local_env.json`，记下 `device_id`
3. 在 Linux/macOS 跑 `./login.sh` 生成凭证后，把凭证 `auth.deviceId` 替换为上面的真实 `device_id`
4. 之后 `./signin.sh` 可正常签到——**服务端只校验 device_id 与账号绑定关系，不校验请求来源平台**（已实测）

**方案 B**：直接在能常开的 Windows 机器上跑，配计划任务定时签到。

> 风险：借用设备长期不活跃可能被风控；服务端未来可能加「设备在线」校验。

---

## Bark 通知

```bash
export BARK_URL="https://api.day.app/你的Key"
./signin.sh
```

推送示例：`✅ TRAE 签到成功 总计1 | 成功1 | 已签0 | 失败0 | 签到奖励1800 | 总剩余5626`

## 定时签到

### GitHub Actions（推荐）

1. 推送仓库到 GitHub
2. Settings → Secrets and variables → Actions 添加：

   | Secret | 值 |
   |---|---|
   | `TRAE_AUTH_1` | 账号凭证 JSON（**必须含已绑定设备的 deviceId**） |
   | `TRAE_AUTH_2` | 多账号依次添加 |
   | `BARK_URL` | 可选，Bark 推送 |

3. 每天北京时间 08:00 自动执行，也可手动触发

> ⚠️ Fork 的仓库默认禁用定时任务，需在 Actions 页启用 Workflows。
> ⚠️ Secret 凭证里 deviceId 若是随机值，Actions 中签到会失败（9074）。

### Crontab

```bash
0 8 * * * cd /path/to/trae-signin && bash signin.sh >> signin.log 2>&1
```

---

## 目录结构

```
cmd/signin/main.go        签到入口（编译为 signin_bin / signin_bin.exe）
internal/auth/auth.go     凭证解析与原子写回
internal/upstream/upstream.go  上游 API（签到/积分/刷新，含业务错误码校验）
login.sh / login.ps1      登录脚本（Linux/macOS/Windows，复用本机桌面端绑定设备 ID）
signin.sh                 签到脚本（含 Bark 通知）
crontab.txt               Crontab 配置参考
auths/                    （gitignored）凭证文件
```

## 常见问题

**Q：显示「签到成功」但积分不涨？**
旧版本误报成功（未校验 body `code`）。更新后失败会如实显示错误码；若仍 9074，是 deviceId 未绑定真实设备。

**Q：报 9074「参与用户太多」？**
通常为 deviceId 未绑定，或该绑定设备当日已签。用桌面端绑定后重新生成凭证即可。

**Q：为什么「积分」在下降？**
那是通用积分（使用消耗）。签到发的看「签到奖励」列，每天 +200。

**Q：一台电脑能签几个账号？**
官方：一台设备一天只能签一个账号。

## 安全说明

- token 仅存 `auths/`（gitignored），不上传 Git
- 终端不打印 token，回调链接输入不回显

## 更新记录

- 修复签到被设备绑定拒绝时误报成功（校验响应 `code`）
- 积分改用权威 `usage_summary`，单独展示「签到奖励」累计
- `login.ps1` / `login.sh` 登录时复用本机桌面端已绑定的设备 ID（需先用桌面端登录该账号）
- 签到遇限流自动重试

## 致谢

[traework2api](https://github.com/Sliverkiss/traework2api) · [Bark](https://github.com/Finb/Bark)

## License

MIT
