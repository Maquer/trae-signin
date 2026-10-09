#!/usr/bin/env bash
# signin.sh — TRAE 批量签到脚本，签到后通过 Bark 推送通知
set -e
cd "$(dirname "$0")"

# Bark 推送地址：运行前请自行 export BARK_URL='https://api.day.app/你的Key'
# 注意：不要将真实 Bark key 硬编码进仓库。GitHub Actions 通过 secrets.BARK_URL 注入。
BARK_URL="${BARK_URL:-}"
if [ -z "$BARK_URL" ]; then
  echo "⚠️ 未设置 BARK_URL，跳过 Bark 推送。本地运行可先: export BARK_URL='https://api.day.app/你的Key'"
fi

go build -o signin_bin ./cmd/signin

# 执行签到并捕获输出
SIGNIN_OUTPUT=$(./signin_bin "${1:-auths}" 2>&1)
SIGNIN_EXIT=$?

echo "$SIGNIN_OUTPUT"

# 提取关键信息用于 Bark 推送
TOTAL=$(echo "$SIGNIN_OUTPUT" | grep -oP '总计=\K\d+' || echo "?")
OK=$(echo "$SIGNIN_OUTPUT" | grep -oP '签到成功=\K\d+' || echo "?")
ALREADY=$(echo "$SIGNIN_OUTPUT" | grep -oP '已签=\K\d+' || echo "?")
FAIL=$(echo "$SIGNIN_OUTPUT" | grep -oP '失败=\K\d+' || echo "?")
# 未确认：接口返回成功但未真正到账（疑似风控），不计入失败但要提示
UNCONF=$(echo "$SIGNIN_OUTPUT" | grep -oP '未确认=\K\d+' || echo "0")
UNCONF=${UNCONF:-0}
# 设备异常：设备号未被服务端认可（code=9074）
BUSY=$(echo "$SIGNIN_OUTPUT" | grep -oP '设备异常=\K\d+' || echo "0")
BUSY=${BUSY:-0}

# 提取每个账号的信息（表格列：UID | 昵称 | 状态 | 总计 | 月赠 | 签到 | 详情）
ACCOUNTS=""
while IFS= read -r line; do
    if echo "$line" | grep -qP '│\s+\d+'; then
        nick=$(echo "$line" | sed 's/│/\n/g' | sed -n '3p' | xargs)
        status=$(echo "$line" | sed 's/│/\n/g' | sed -n '4p' | xargs)
        total=$(echo "$line" | sed 's/│/\n/g' | sed -n '5p' | xargs)
        chk=$(echo "$line" | sed 's/│/\n/g' | sed -n '7p' | xargs)
        ACCOUNTS="${ACCOUNTS}${nick} ${status} 总${total}(签到${chk})\n"
    fi
done <<< "$SIGNIN_OUTPUT"

# 构建 Bark 推送内容
TITLE="TRAE 签到"
if [ "$BUSY" -gt 0 ] 2>/dev/null; then
    TITLE="🔑 TRAE 设备号异常"
elif [ "$UNCONF" -gt 0 ] 2>/dev/null; then
    TITLE="⚠️ TRAE 签到未确认"
elif [ "$SIGNIN_EXIT" -eq 0 ]; then
    if [ "$OK" -gt 0 ] 2>/dev/null; then
        TITLE="✅ TRAE 签到成功"
    elif [ "$FAIL" -gt 0 ] 2>/dev/null; then
        TITLE="⚠️ TRAE 签到异常"
    else
        TITLE="📌 TRAE 已签到"
    fi
else
    TITLE="❌ TRAE 签到失败"
fi

BODY="总计${TOTAL} | 成功${OK} | 已签${ALREADY} | 未确认${UNCONF} | 设备异常${BUSY} | 失败${FAIL}\n${ACCOUNTS}"

# 发送 Bark 通知
if [ -n "$BARK_URL" ]; then
  curl -s -X POST "$BARK_URL/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$TITLE'))")/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$BODY'))")" > /dev/null 2>&1 || true
  echo "📲 Bark 通知已发送"
else
  echo "📲 未配置 BARK_URL，跳过 Bark 推送"
fi
