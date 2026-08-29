#Requires -Version 5.1
<#
login.ps1 — TRAE SOLO (CN) 登录工具（Windows PowerShell 版）
流程：生成登录链接 → 浏览器登录 → 粘贴回调链接 → 换取 Token → 保存凭证 → 自动签到+查积分
与 login.sh 功能一致，纯 PowerShell 实现，无需 Python / Go。
用法：  powershell -ExecutionPolicy Bypass -File login.ps1
可选参数：
  -NoOpen    不自动打开浏览器
  -NoSignin  登录换 token 后不自动签到
#>
[CmdletBinding()]
param(
    [switch]$NoOpen,
    [switch]$NoSignin
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$CLIENT_ID    = "en1oxy7wnw8j9n"
$APP_VERSION  = "0.1.43"
$API_HOST     = "https://api.trae.com.cn"
$UG_HOST      = "https://api.trae.cn"
$LOGIN_BASE   = "https://www.trae.cn/authorization"
$CALLBACK_URL = "http://127.0.0.1:18080/authorize"
$AUTH_DIR     = "auths"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AuthRoot  = Join-Path $ScriptDir $AUTH_DIR
if (-not (Test-Path $AuthRoot)) { New-Item -ItemType Directory -Path $AuthRoot | Out-Null }

# 需要 System.Web 的 HttpUtility 来解析回调查询串
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

function New-Hex {
    param([int]$Bytes = 16)
    $b = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return ($b | ForEach-Object { $_.ToString("x2") }) -join ""
}

function New-UrlEncode([string]$s) {
    return [System.Uri]::EscapeDataString($s)
}

function Get-UnixTime {
    return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# 兼容 utf8 无 BOM 输出
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function ConvertFrom-SafeJson([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    try { return ($Raw | ConvertFrom-Json) } catch { }
    try { return ([System.Uri]::UnescapeDataString($Raw) | ConvertFrom-Json) } catch { }
    return $null
}

function Invoke-JsonPost {
    param(
        [string]$Url,
        [hashtable]$Body,
        [hashtable]$Headers,
        [int]$TimeoutSec = 60
    )
    $json = $Body | ConvertTo-Json -Compress
    return Invoke-RestMethod -Uri $Url -Method Post -Body $json `
        -ContentType "application/json" -Headers $Headers -TimeoutSec $TimeoutSec
}

Write-Host "============================================================"
Write-Host "  TRAE SOLO 登录 - 纯签到版 (Windows)"
Write-Host "============================================================"
Write-Host ""
Write-Host "步骤："
Write-Host "  1. 浏览器会自动打开登录链接，用手机号/验证码登录"
Write-Host "  2. 登录成功后浏览器会跳到打不开的 127.0.0.1 地址"
Write-Host "  3. 复制浏览器地址栏的完整链接，粘贴到下面（输入不回显）"
Write-Host ""

# 设备 ID：优先复用本机 TraeWork 桌面端已绑定的设备 ID（签到按设备校验）。
# 注意：必须先在本机用 TraeWork 桌面端登录过目标账号完成绑定，这里读取到的才是有效设备 ID；
# 否则退化为随机 ID，签到会被服务端拒绝（9074）。
$soloEnvPath = Join-Path $env:APPDATA 'TRAE SOLO CN\ModularData\ckg_server\local_env.json'
$deviceId = $null
if (Test-Path $soloEnvPath) {
    try {
        $soloEnv = Get-Content $soloEnvPath -Raw | ConvertFrom-Json
        if ($soloEnv.device_id) {
            $deviceId = [string]$soloEnv.device_id
            Write-Host "已复用本机 TraeWork 桌面端设备 ID: $deviceId" -ForegroundColor Green
        }
    } catch { }
}
if (-not $deviceId) {
    $deviceId = New-Hex 16
    Write-Host "⚠️ 未找到本机 TraeWork 桌面端已绑定的设备 ID，将使用随机 deviceId；"
    Write-Host "   签到按设备绑定，随机 ID 会被拒绝。请先安装 TraeWork 桌面端并用此账号登录一次。" -ForegroundColor Yellow
}
$machineId = New-Hex 16
$traceId   = New-Hex 8

$params = [ordered]@{
    login_version     = "1"
    auth_from         = "solo"
    login_channel     = "native_ide"
    plugin_version    = "2.3.62834"
    auth_type         = "local"
    client_id         = $CLIENT_ID
    redirect          = "0"
    login_trace_id    = $traceId
    auth_callback_url = $CALLBACK_URL
    machine_id        = $machineId
    device_id         = $deviceId
    x_device_id       = $deviceId
    x_machine_id      = $machineId
    x_device_brand    = "PC"
    x_device_type     = "PC"
    x_os_version      = "1.0"
    x_app_version     = $APP_VERSION
    x_app_type        = "stable"
}

$query = ($params.GetEnumerator() | ForEach-Object {
        "$(New-UrlEncode $_.Key)=$(New-UrlEncode ([string]$_.Value))"
    }) -join "&"
$loginUrl = "$LOGIN_BASE`?$query"

Write-Host "请在浏览器打开："
Write-Host ""
Write-Host "  $loginUrl"
Write-Host ""

if (-not $NoOpen) {
    try {
        Start-Process $loginUrl
        Write-Host "(已尝试自动打开浏览器...)"
    } catch {
        Write-Host "⚠️ 自动打开浏览器失败，请手动复制上面的链接" -ForegroundColor Yellow
    }
}

# 隐藏输入回调链接
Write-Host "登录完成后，请复制浏览器地址栏的完整回调链接：" -ForegroundColor Cyan
$secure = Read-Host -Prompt "回调链接(不回显)" -AsSecureString
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $callback = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
if ([string]::IsNullOrWhiteSpace($callback)) {
    Write-Host "未输入回调链接，已取消" -ForegroundColor Yellow
    exit 1
}

# 解析回调查询参数（HttpUtility 会自动 URL 解码）
$qs = [System.Web.HttpUtility]::ParseQueryString(([Uri]$callback).Query)
$refreshToken = $qs["refreshToken"]
$userInfo     = ConvertFrom-SafeJson $qs["userInfo"]
$userJwt      = ConvertFrom-SafeJson $qs["userJwt"]

$uid      = if ($userInfo.UserID)     { [string]$userInfo.UserID }     else { "" }
$nickname = if ($userInfo.ScreenName) { [string]$userInfo.ScreenName } else { "" }
$jwtToken = if ($userJwt.Token)        { [string]$userJwt.Token }       else { "" }
$jwtRefresh = if ($userJwt.RefreshToken) { [string]$userJwt.RefreshToken } else { "" }
if (-not $refreshToken) { $refreshToken = $jwtRefresh }

$token = ""; $newRefresh = $refreshToken; $expiresAt = [int64]0
if ($refreshToken) {
    Write-Host "[*] 正在调用 ExchangeToken 换取 access token ..."
    $body = @{ ClientID = $CLIENT_ID; RefreshToken = $refreshToken; ClientSecret = "-"; UserID = "" }
    $headers = @{ "User-Agent" = "Trae/$APP_VERSION" }
    try {
        $resp = Invoke-JsonPost -Url "$API_HOST/cloudide/api/v3/trae/oauth/ExchangeToken" `
            -Body $body -Headers $headers
    } catch {
        Write-Host "[!] ExchangeToken 请求失败: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    $token = if ($resp.Result.Token) { [string]$resp.Result.Token } else { "" }
    if (-not $token) {
        Write-Host "[!] ExchangeToken 失败: $($resp | ConvertTo-Json -Compress -Depth 5)" -ForegroundColor Red
        exit 1
    }
    $newRefresh = if ($resp.Result.RefreshToken) { [string]$resp.Result.RefreshToken } else { $refreshToken }
    $expiresAt = [int64]($resp.Result.TokenExpireAt)
    if ($expiresAt -gt 1000000000000) { $expiresAt = [int64]($expiresAt / 1000) }
    if ($expiresAt -le (Get-UnixTime)) {
        $dur = [int64]($resp.Result.TokenExpireDuration)
        if ($dur -le 0) { $dur = 1209600 }
        $expiresAt = (Get-UnixTime) + $dur
    }
    Write-Host "[*] ExchangeToken 成功"
} else {
    $token = $jwtToken
    if ($userJwt.TokenExpireAt) { $expiresAt = [int64]$userJwt.TokenExpireAt }
    if ($expiresAt -gt 1000000000000) { $expiresAt = [int64]($expiresAt / 1000) }
    if (-not $token) {
        Write-Host "[!] 回调链接缺少 refreshToken" -ForegroundColor Red
        exit 1
    }
    Write-Host "[*] 使用 userJwt 的 Token 兜底"
}

# 获取用户信息
try {
    $ui = Invoke-JsonPost -Url "$API_HOST/cloudide/api/v3/trae/GetUserInfo" `
        -Body @{ ReqSource = "IDE"; IDEVersion = $APP_VERSION } `
        -Headers @{ "x-cloudide-token" = $token; "User-Agent" = "Trae/$APP_VERSION" }
    if ($ui.Result.UserID) {
        $uid = [string]$ui.Result.UserID
        if ($ui.Result.ScreenName) { $nickname = [string]$ui.Result.ScreenName }
    }
} catch {
    Write-Host "[*] GetUserInfo 失败: $($_.Exception.Message)" -ForegroundColor Yellow
}

if (-not $uid) {
    Write-Host "[!] 未能获取 uid" -ForegroundColor Red
    exit 1
}

# 保存凭证（与 login.sh 输出格式一致，供 signin 工具解析）
$authFile = Join-Path $AuthRoot "trae-$uid.json"
if (Test-Path $authFile) {
    Write-Host "账号已存在（uid=$uid），将覆盖更新凭证" -ForegroundColor Yellow
    $action = "覆盖"
} else {
    Write-Host "新账号（uid=$uid），新增 auth 文件"
    $action = "新增"
}

$authDoc = [ordered]@{
    account = [ordered]@{
        uid          = $uid
        enterpriseId = ""
        nickname     = $nickname
    }
    auth    = [ordered]@{
        accessToken  = $token
        refreshToken = $newRefresh
        expiresAt    = $expiresAt
        domain       = "trae.cn"
        apiHost      = $API_HOST
        machineId    = $machineId
        deviceId     = $deviceId
    }
}
$authJson = $authDoc | ConvertTo-Json -Depth 5
Write-Utf8NoBom -Path $authFile -Text $authJson
Write-Host "已保存（$action）: $authFile"

# 自动签到 + 查积分
if (-not $NoSignin) {
    Write-Host ""
    Write-Host "自动签到 + 查积分..."
    $ugHeaders = @{
        "Content-Type"   = "application/json"
        "Authorization"  = "Cloud-IDE-JWT $token"
        "X-User-Region"  = "CN"
        "X-Device-Id"    = $deviceId
        "X-Machine-Id"   = $machineId
    }
    try {
        $st = Invoke-RestMethod -Uri "$UG_HOST/trae/api/v2/ug/checkin_credits/status" `
            -Method Post -Body "{}" -ContentType "application/json" `
            -Headers $ugHeaders -TimeoutSec 15
        if (-not $st.checked_in -and $st.enable) {
            $r = Invoke-RestMethod -Uri "$UG_HOST/trae/api/v2/ug/checkin_credits/claim" `
                -Method Post -Body "{}" -ContentType "application/json" `
                -Headers $ugHeaders -TimeoutSec 15
            if ($r.code -and $r.code -ne 0 -and $r.code -ne 200) {
                Write-Host "签到被拒: $($r.message)" -ForegroundColor Yellow
            } else {
                Write-Host "签到: $($r.message)"
            }
        } else {
            Write-Host "签到状态: checked_in=$($st.checked_in) enable=$($st.enable)"
        }
    } catch {
        Write-Host "签到: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    try {
        $ent = Invoke-RestMethod -Uri "$UG_HOST/trae/api/v2/pay/ide_user_ent_usage" `
            -Method Post -Body "{}" -ContentType "application/json" `
            -Headers $ugHeaders -TimeoutSec 15
        $signin = [int64]0
        foreach ($p in $ent.user_entitlement_pack_list) {
            $name = $p.entitlement_base_info.product_extra.package_extra.package_name
            if ($name -eq "签到奖励") {
                $signin += [int64]$p.entitlement_base_info.quota.credits_limit
            }
        }
        if ($ent.usage_summary.total_amount) {
            $remain = [int64]$ent.usage_summary.total_amount - [int64]$ent.usage_summary.consumed_amount
            Write-Host "当前积分: 剩余$remain（累计签到奖励$signin）"
        } else {
            Write-Host "当前积分: 累计签到奖励$signin"
        }
    } catch {
        Write-Host "查积分: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "  登录完成！"
Write-Host "  UID: $uid"
Write-Host "  Nickname: $(if ($nickname) { $nickname } else { '（未获取到）' })"
if ($expiresAt -gt 0) {
    $expStr = [DateTimeOffset]::FromUnixTimeSeconds($expiresAt).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
} else {
    $expStr = "$expiresAt"
}
Write-Host "  有效期: $expStr"
Write-Host "============================================================"
Write-Host ""
Write-Host "下一步：运行 signin.sh（或 signin_bin.exe）即可批量签到"
