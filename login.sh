#!/usr/bin/env bash
# login.sh — TRAE SOLO 登录：生成登录链接 → 浏览器登录 → 粘贴回调链接 → 换 token 落盘。
set -euo pipefail

cd "$(dirname "$0")"
AUTH_DIR="./auths"
CLIENT_ID="en1oxy7wnw8j9n"
APP_VERSION="0.1.43"
API_HOST="https://api.trae.com.cn"

mkdir -p "$AUTH_DIR"

# 设备 ID：优先复用本机 TraeWork 桌面端已绑定的设备 ID（签到按设备校验）。
# 注意：必须先在本机用 TraeWork 桌面端登录过目标账号完成绑定，这里读取到的才是有效设备 ID；
# 否则退化为随机 ID，签到会被服务端拒绝。
TRAE_ENV_FILE=""
if [ -n "$APPDATA" ]; then
  # Git Bash(Windows) 下 $APPDATA 是反斜杠路径，先转成 bash 可识别的正斜杠
  APPDATA_POSIX="${APPDATA//\\//}"
  if [ -f "$APPDATA_POSIX/TRAE SOLO CN/ModularData/ckg_server/local_env.json" ]; then
    TRAE_ENV_FILE="$APPDATA_POSIX/TRAE SOLO CN/ModularData/ckg_server/local_env.json"
  fi
fi
if [ -z "$TRAE_ENV_FILE" ] && [ -f "$HOME/Library/Application Support/TRAE SOLO CN/ModularData/ckg_server/local_env.json" ]; then
  TRAE_ENV_FILE="$HOME/Library/Application Support/TRAE SOLO CN/ModularData/ckg_server/local_env.json"
fi
if [ -z "$TRAE_ENV_FILE" ] && [ -f "$HOME/.config/TRAE SOLO CN/ModularData/ckg_server/local_env.json" ]; then
  TRAE_ENV_FILE="$HOME/.config/TRAE SOLO CN/ModularData/ckg_server/local_env.json"
fi
DEVICE_ID=""
if [ -n "$TRAE_ENV_FILE" ] && command -v python3 >/dev/null 2>&1; then
  DEVICE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["device_id"])' "$TRAE_ENV_FILE" 2>/dev/null)"
fi
if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID="$(openssl rand -hex 16 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(16))')"
  echo "⚠️ 未找到本机 TraeWork 桌面端已绑定的设备 ID（local_env.json），使用随机 deviceId；" >&2
  echo "   签到按设备绑定，随机 ID 会被拒绝。请先在 Windows 安装 TraeWork 桌面端并用此账号登录一次。" >&2
else
  echo "已复用本机 TraeWork 桌面端设备 ID: $DEVICE_ID"
fi

MACHINE_ID="$(openssl rand -hex 16 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(16))')"

echo "============================================================"
echo "  TRAE SOLO 登录 - 纯签到版"
echo "============================================================"
echo ""
echo "步骤："
echo "  1. 在浏览器打开下面链接，用手机号/验证码登录"
echo "  2. 登录成功后浏览器会跳到打不开的 127.0.0.1 地址"
echo "  3. 复制浏览器地址栏的完整链接，粘贴到下面"
echo ""

LOGIN_URL="$(MACHINE_ID="$MACHINE_ID" DEVICE_ID="$DEVICE_ID" CLIENT_ID="$CLIENT_ID" APP_VERSION="$APP_VERSION" python3 - <<'PYEOF'
import os, secrets, urllib.parse

params = {
    "login_version": "1",
    "auth_from": "solo",
    "login_channel": "native_ide",
    "plugin_version": "2.3.62834",
    "auth_type": "local",
    "client_id": os.environ["CLIENT_ID"],
    "redirect": "0",
    "login_trace_id": secrets.token_hex(8),
    "auth_callback_url": "http://127.0.0.1:18080/authorize",
    "machine_id": os.environ["MACHINE_ID"],
    "device_id": os.environ["DEVICE_ID"],
    "x_device_id": os.environ["DEVICE_ID"],
    "x_machine_id": os.environ["MACHINE_ID"],
    "x_device_brand": "PC",
    "x_device_type": "PC",
    "x_os_version": "1.0",
    "x_app_version": os.environ["APP_VERSION"],
    "x_app_type": "stable",
}
print("https://www.trae.cn/authorization?" + urllib.parse.urlencode(params))
PYEOF
)"

echo "请在浏览器打开："
echo ""
echo "  $LOGIN_URL"
echo ""

read -rp "登录完成后，请粘贴浏览器地址栏的完整回调链接（不回显）: " -s callback_url || true
echo ""
if [[ -z "$callback_url" ]]; then
    echo "未输入回调链接，已取消"
    exit 1
fi

RESULT=$(CLIENT_ID="$CLIENT_ID" API_HOST="$API_HOST" APP_VERSION="$APP_VERSION" \
MACHINE_ID="$MACHINE_ID" DEVICE_ID="$DEVICE_ID" CALLBACK_URL="$callback_url" python3 - <<'PYEOF'
import json, os, sys, time, urllib.parse, urllib.request, urllib.error

CLIENT_ID = os.environ["CLIENT_ID"]
API_HOST = os.environ["API_HOST"]
APP_VERSION = os.environ["APP_VERSION"]
MACHINE_ID = os.environ["MACHINE_ID"]
DEVICE_ID = os.environ["DEVICE_ID"]
CALLBACK = os.environ["CALLBACK_URL"]

def http_post_json(url, body, headers, timeout=60, retries=2):
    req = urllib.request.Request(url, method="POST")
    for k, v in headers.items():
        req.add_header(k, v)
    data = json.dumps(body).encode()
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, data, timeout=timeout) as resp:
                return json.loads(resp.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            raw = e.read().decode(errors="replace")
            print(f"[!] HTTP {e.code}: {raw[:400]}", file=sys.stderr)
            sys.exit(1)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt < retries:
                print(f"[*] 网络瞬时错误，重试 {attempt + 1}/{retries}: {e}", file=sys.stderr)
                time.sleep(1)
                continue
            print(f"[!] 请求失败: {e}", file=sys.stderr)
            sys.exit(1)

def parse_json_param(raw):
    if not raw:
        return None
    for val in (raw, urllib.parse.unquote(raw)):
        try:
            obj = json.loads(val)
            if isinstance(obj, dict):
                return obj
        except Exception:
            continue
    return None

qs = urllib.parse.parse_qs(urllib.parse.urlparse(CALLBACK).query)
refresh_token = (qs.get("refreshToken") or [""])[0]
user_info = parse_json_param((qs.get("userInfo") or [""])[0]) or {}
user_jwt = parse_json_param((qs.get("userJwt") or [""])[0]) or {}

uid = str(user_info.get("UserID") or "")
nickname = str(user_info.get("ScreenName") or "")

jwt_token = str(user_jwt.get("Token") or "")
jwt_refresh = str(user_jwt.get("RefreshToken") or "")
if not refresh_token:
    refresh_token = jwt_refresh

token, new_refresh, expires_at = "", refresh_token, 0
if refresh_token:
    body = {"ClientID": CLIENT_ID, "RefreshToken": refresh_token, "ClientSecret": "-", "UserID": ""}
    resp = http_post_json(API_HOST + "/cloudide/api/v3/trae/oauth/ExchangeToken", body,
                          {"Content-Type": "application/json", "User-Agent": f"Trae/{APP_VERSION}"})
    result = resp.get("Result") or {}
    token = result.get("Token") or ""
    if not token:
        print("[!] ExchangeToken 失败: " + json.dumps(resp, ensure_ascii=False)[:300], file=sys.stderr)
        sys.exit(1)
    new_refresh = result.get("RefreshToken") or refresh_token
    expires_at = int(result.get("TokenExpireAt") or 0)
    if expires_at > 10**12:
        expires_at //= 1000
    if expires_at <= time.time():
        expires_at = int(time.time()) + int(result.get("TokenExpireDuration") or 1209600)
    print(f"[*] ExchangeToken 成功")
else:
    token = jwt_token
    expires_at = int(user_jwt.get("TokenExpireAt") or 0)
    if expires_at > 10**12:
        expires_at //= 1000
    if not token:
        print("[!] 回调链接缺少 refreshToken", file=sys.stderr)
        sys.exit(1)
    print("[*] 使用 userJwt 的 Token 兜底")

try:
    ui = http_post_json(API_HOST + "/cloudide/api/v3/trae/GetUserInfo",
                        {"ReqSource": "IDE", "IDEVersion": APP_VERSION},
                        {"Content-Type": "application/json", "x-cloudide-token": token,
                         "User-Agent": f"Trae/{APP_VERSION}"})
    u = ui.get("Result") or ui
    if u.get("UserID"):
        uid = str(u.get("UserID") or uid)
        nickname = str(u.get("ScreenName") or nickname)
except Exception as e:
    print(f"[*] GetUserInfo 失败: {e}", file=sys.stderr)

if not uid:
    print("[!] 未能获取 uid", file=sys.stderr)
    sys.exit(1)

out = {
    "uid": uid, "nickname": nickname, "access_token": token,
    "refresh_token": new_refresh, "expires_at": expires_at,
    "api_host": API_HOST, "machine_id": MACHINE_ID, "device_id": DEVICE_ID,
}
print("JSON:" + json.dumps(out))
PYEOF
)

CRED=$(echo "$RESULT" | sed -n 's/^JSON://p')
if [[ -z "$CRED" ]]; then
    echo "$RESULT" >&2
    echo "解析/换 token 失败"
    exit 1
fi

ACCT_UID=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['uid'])")
NICKNAME=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['nickname'])")
TOKEN=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
REFRESH=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['refresh_token'])")
EXPIRES_AT=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['expires_at'])")

AUTH_FILE="$AUTH_DIR/trae-${ACCT_UID}.json"
if [[ -f "$AUTH_FILE" ]]; then
    echo "账号已存在（uid=$ACCT_UID），将覆盖更新凭证"
    ACTION="覆盖"
else
    echo "新账号（uid=$ACCT_UID），新增 auth 文件"
    ACTION="新增"
fi

MACHINE_ID="$MACHINE_ID" DEVICE_ID="$DEVICE_ID" TOKEN="$TOKEN" REFRESH="$REFRESH" \
EXPIRES_AT="$EXPIRES_AT" ACCT_UID="$ACCT_UID" NICKNAME="$NICKNAME" AUTH_FILE="$AUTH_FILE" \
ACTION="$ACTION" python3 - <<'PYEOF'
import json, os
auth = {
    "account": {"uid": os.environ["ACCT_UID"], "enterpriseId": "", "nickname": os.environ["NICKNAME"]},
    "auth": {
        "accessToken": os.environ["TOKEN"],
        "refreshToken": os.environ["REFRESH"],
        "expiresAt": int(os.environ["EXPIRES_AT"]),
        "domain": "trae.cn",
        "apiHost": "https://api.trae.com.cn",
        "machineId": os.environ["MACHINE_ID"],
        "deviceId": os.environ["DEVICE_ID"],
    },
}
with open(os.environ["AUTH_FILE"], "w") as f:
    json.dump(auth, f, indent=1, ensure_ascii=False)
print(f"已保存（{os.environ['ACTION']}）: {os.environ['AUTH_FILE']}")
PYEOF

# 自动签到 + 查积分
TOKEN="$TOKEN" DEVICE_ID="$DEVICE_ID" MACHINE_ID="$MACHINE_ID" python3 - <<'PYEOF'
import json, os, urllib.request
UG = "https://api.trae.cn"
HDRS = {
    "Content-Type": "application/json",
    "Authorization": "Cloud-IDE-JWT " + os.environ["TOKEN"],
    "X-User-Region": "CN",
    "X-Device-Id": os.environ["DEVICE_ID"],
    "X-Machine-Id": os.environ["MACHINE_ID"],
}
def post(path, body=None):
    data = json.dumps(body).encode() if body is not None else b"{}"
    req = urllib.request.Request(UG + path, method="POST", data=data, headers=HDRS)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode() or "{}")
try:
    st = post("/trae/api/v2/ug/checkin_credits/status")
    if not st.get("checked_in") and st.get("enable"):
        r = post("/trae/api/v2/ug/checkin_credits/claim")  # 设备绑定通过 header X-Device-Id 传递
        code = r.get("code")
        if code and code not in (0, 200):
            print(f"签到被拒: {r.get('message', 'code %s' % code)}")
        else:
            print(f"签到: {r.get('message', 'success')}")
    else:
        print(f"签到状态: checked_in={st.get('checked_in')} enable={st.get('enable')}")
except Exception as e:
    print(f"签到: {e}")
try:
    ent = post("/trae/api/v2/pay/ide_user_ent_usage")
    us = ent.get("usage_summary") or {}
    packs = ent.get("user_entitlement_pack_list") or []
    signin = 0
    for p in packs:
        name = ((p.get("entitlement_base_info") or {}).get("product_extra") or {}).get("package_extra", {}).get("package_name", "")
        if name == "签到奖励":
            signin += int((p.get("entitlement_base_info") or {}).get("quota", {}).get("credits_limit", 0))
    if us.get("total_amount"):
        remain = int(us.get("total_amount")) - int(us.get("consumed_amount", 0))
        print(f"当前积分: 剩余{remain}（累计签到奖励{signin}）")
    else:
        print(f"当前积分: 累计签到奖励{signin}")
except Exception as e:
    print(f"查积分: {e}")
PYEOF

echo ""
echo "============================================================"
echo "  登录完成！"
echo "  UID: $ACCT_UID"
echo "  Nickname: ${NICKNAME:-（未获取到）}"
echo "  有效期: $(date -d "@$EXPIRES_AT" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$EXPIRES_AT")"
echo "============================================================"
