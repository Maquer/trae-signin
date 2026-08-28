#!/usr/bin/env bash
# signin.sh — TRAE 批量签到脚本，签到后通过 Bark 推送通知
# 兼容 Linux / macOS / Windows(Git Bash)
set -u

cd "$(dirname "$0")"

# Bark 推送地址：运行前请自行 export BARK_URL='https://api.day.app/你的Key'
# 注意：不要将真实 Bark key 硬编码进仓库。GitHub Actions 通过 secrets.BARK_URL 注入。
BARK_URL="${BARK_URL:-}"
BARK_URL="${BARK_URL%/}"  # 去掉末尾斜杠，避免生成 //title/body 双重斜杠
if [ -z "$BARK_URL" ]; then
  echo "⚠️ 未设置 BARK_URL，跳过 Bark 推送。本地运行可先: export BARK_URL='https://api.day.app/你的Key'"
fi

# 编译签到工具；未安装 Go 时回退到已有编译产物
if command -v go >/dev/null 2>&1; then
  if ! go build -o signin_bin ./cmd/signin; then
    if [ -x "./signin_bin" ] || [ -x "./signin_bin.exe" ]; then
      echo "⚠️ 编译失败，使用现有编译产物 signin_bin"
    else
      echo "❌ 编译失败且无可用编译产物"
      exit 1
    fi
  fi
elif [ -x "./signin_bin" ] || [ -x "./signin_bin.exe" ]; then
  echo "⚠️ 未检测到 Go 环境，使用现有编译产物 signin_bin"
else
  echo "❌ 未检测到 Go 环境，且没有可用的 signin_bin 编译产物"
  echo "   请安装 Go 后重试，或运行 login.sh / login.ps1 完成登录"
  exit 1
fi

# Windows 上 Go 编译产物会带 .exe 后缀
BIN="./signin_bin"
if [ ! -x "$BIN" ] && [ -x "$BIN.exe" ]; then
  BIN="$BIN.exe"
fi

# 捕获输出与退出码（不退出，保证后面能正常发 Bark）
SIGNIN_OUTPUT="$("$BIN" "${1:-auths}" 2>&1)"
SIGNIN_EXIT=$?
echo "$SIGNIN_OUTPUT"

# 提取汇总数据（避免 GNU 专属 grep -oP）
TOTAL="?"; OK="?"; ALREADY="?"; FAIL="?"
if [[ "$SIGNIN_OUTPUT" =~ 总计=([0-9]+) ]]; then TOTAL="${BASH_REMATCH[1]}"; fi
if [[ "$SIGNIN_OUTPUT" =~ 签到成功=([0-9]+) ]]; then OK="${BASH_REMATCH[1]}"; fi
if [[ "$SIGNIN_OUTPUT" =~ 已签=([0-9]+) ]]; then ALREADY="${BASH_REMATCH[1]}"; fi
if [[ "$SIGNIN_OUTPUT" =~ 失败=([0-9]+) ]]; then FAIL="${BASH_REMATCH[1]}"; fi

# 提取每个账号信息（数据行以 │ 开头，第2列为数字 UID）
ACCOUNTS=""
while IFS= read -r line; do
  case "$line" in
    \│*)
      # 用 SOH 分隔，避免多字节字符在 tr/sed 下的移植性问题
      line2="${line//│/$'\x01'}"
      IFS=$'\x01' read -r -a fields <<< "$line2"
      uid="${fields[1]}"; nick="${fields[2]}"; status="${fields[3]}"; credits="${fields[4]}"
      uid="$(echo "$uid" | xargs)"; nick="$(echo "$nick" | xargs)"
      status="$(echo "$status" | xargs)"; credits="$(echo "$credits" | xargs)"
      if [[ "$uid" =~ ^[0-9]+$ ]]; then
        ACCOUNTS="${ACCOUNTS}${nick} ${status} 积分${credits}"$'\n'
      fi
      ;;
  esac
done <<< "$SIGNIN_OUTPUT"

# 纯 bash URL 编码（UTF-8 按字节编码），作为无 python3 时的回退
urlencode() {
  local s="$1" i c o=""
  # local 使 LC_ALL 只在函数内生效，避免污染后续命令的 UTF-8 环境
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9_.~-]) o+="$c" ;;
      *) o+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$o"
}

encode() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$1" 2>/dev/null || urlencode "$1"
  else
    urlencode "$1"
  fi
}

# 构建 Bark 推送内容
TITLE="TRAE 签到"
if [ "$SIGNIN_EXIT" -eq 0 ]; then
  if [ "${OK:-0}" -gt 0 ] 2>/dev/null; then
    TITLE="✅ TRAE 签到成功"
  elif [ "${FAIL:-0}" -gt 0 ] 2>/dev/null; then
    TITLE="⚠️ TRAE 签到异常"
  else
    TITLE="📌 TRAE 已签到"
  fi
else
  TITLE="❌ TRAE 签到失败"
fi

BODY="总计${TOTAL} | 成功${OK} | 已签${ALREADY} | 失败${FAIL}"$'\n'"${ACCOUNTS}"

# 发送 Bark 通知
if [ -n "$BARK_URL" ]; then
  TITLE_ENC="$(encode "$TITLE")"
  BODY_ENC="$(encode "$BODY")"
  if command -v curl >/dev/null 2>&1; then
    curl -s -X POST "${BARK_URL}/${TITLE_ENC}/${BODY_ENC}" > /dev/null 2>&1 || true
    echo "📲 Bark 通知已发送"
  else
    echo "⚠️ 未找到 curl，无法发送 Bark 通知"
  fi
else
  echo "📲 未配置 BARK_URL，跳过 Bark 推送"
fi
