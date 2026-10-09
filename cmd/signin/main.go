// signin — TRAE 纯签到工具：遍历 auths/trae-*.json 全部账号，
// 自动刷新过期 token，逐个签到并查询积分。
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"errors"
	"trae-signin/internal/auth"
	"trae-signin/internal/upstream"
)

type row struct {
	file    string
	uid     string
	nick    string
	status  string
	detail  string
	remain  int64
	hasRem  bool
	month   int64 // 月赠额度
	checkin int64 // 签到奖励额度
	chkExp  int64 // 签到包过期（Unix 秒）
}

func main() {
	dir := "auths"
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	files, err := filepath.Glob(filepath.Join(dir, "trae-*.json"))
	if err != nil || len(files) == 0 {
		fmt.Fprintf(os.Stderr, "❌ 在 %s 中没有找到 trae-*.json 凭证文件\n", dir)
		fmt.Fprintf(os.Stderr, "   请先运行 login.sh 登录账号\n")
		os.Exit(1)
	}
	sort.Strings(files)
	up := upstream.New()

	var rows []row
	okN, alreadyN, failN, disabledN, unconfirmedN, badDevN := 0, 0, 0, 0, 0, 0

	for _, f := range files {
		r := row{file: filepath.Base(f)}
		raw, err := os.ReadFile(f)
		if err != nil {
			r.status, r.detail = "LOAD_ERR", err.Error()
			rows = append(rows, r)
			failN++
			continue
		}
		a, err := auth.Parse(raw)
		if err != nil {
			r.status, r.detail = "LOAD_ERR", err.Error()
			rows = append(rows, r)
			failN++
			continue
		}
		a.FilePath = f
		r.uid, r.nick = a.UID, a.Nickname

		// 刷新过期 token（2h 缓冲）
		if a.NeedsRefresh(2 * time.Hour) {
			fmt.Printf("🔄 %s token 即将过期，正在刷新...\n", r.uid)
			if err := up.RefreshToken(a); err != nil {
				r.status = "FAIL"
				r.detail = "refresh: " + short(err.Error())
				rows = append(rows, r)
				failN++
				continue
			}
			_ = a.SaveAtomic()
			fmt.Printf("   ✅ token 刷新成功\n")
		}

		// 签到
		checkedIn, _, enable, serr := up.CheckinStatus(a)
		switch {
		case serr != nil:
			if isAlready(serr.Error()) {
				r.status = "ALREADY"
				r.detail = short(serr.Error())
				alreadyN++
			} else {
				r.status = "FAIL"
				r.detail = short(serr.Error())
				failN++
			}
		case checkedIn:
			r.status = "ALREADY"
			r.detail = "今日已签到"
			alreadyN++
		case !enable:
			r.status = "DISABLED"
			r.detail = "签到已禁用"
			disabledN++
		default:
			// claim 前先记录签到包基线，用于事后校验是否真的到账
			beforeChk := int64(-1)
			if sum, e := up.UserCreditSummary(a); e == nil {
				beforeChk = sum.Checkin
			}

			// 服务端限流（code=9074）时退避重试，最多 3 次
			var claimErr error
			for attempt := 1; attempt <= 3; attempt++ {
				claimErr = up.CheckinClaim(a)
				if claimErr == nil || !errors.Is(claimErr, upstream.ErrBusy) {
					break
				}
				if attempt < 3 {
					wait := time.Duration(attempt*attempt) * 3 * time.Second
					fmt.Printf("   ⏳ %s 设备校验未通过，%v 后重试 (%d/3)\n", r.uid, wait, attempt)
					time.Sleep(wait)
				}
			}

			if claimErr != nil {
				if errors.Is(claimErr, upstream.ErrBusy) {
					r.status = "BAD_DEVICE"
					r.detail = "设备号未被认可，需真实设备号(code=9074)"
					badDevN++
				} else {
					r.status = "FAIL"
					r.detail = short(claimErr.Error())
					failN++
				}
				break
			}

			// 回查确认：claim 成功也要验证积分真的到账
			afterIn, _, _, aerr := up.CheckinStatus(a)
			afterChk := int64(0)
			if sum, e := up.UserCreditSummary(a); e == nil {
				afterChk = sum.Checkin
			}
			gained := afterChk > beforeChk && beforeChk >= 0

			switch {
			case afterIn && aerr == nil:
				r.status = "✅ OK"
				r.detail = "签到成功"
				okN++
			case gained:
				// status 未翻转但签到包确实进账了，同样算成功
				r.status = "✅ OK"
				r.detail = "签到成功"
				okN++
			case aerr != nil:
				r.status = "UNCONFIRMED"
				r.detail = "已请求签到，但回查失败: " + short(aerr.Error())
				unconfirmedN++
			default:
				r.status = "UNCONFIRMED"
				r.detail = "接口返回成功但未到账（疑似风控）"
				unconfirmedN++
			}
		}

		// 查积分（拆分签到包 / 月赠包）
		if sum, qerr := up.UserCreditSummary(a); qerr == nil {
			r.remain, r.hasRem = sum.Total, true
			r.month, r.checkin, r.chkExp = sum.Month, sum.Checkin, sum.ChkExp
			// 仅在状态本身无详情时，才用积分信息补充，避免覆盖签到结果
			if r.detail == "" && sum.Checkin > 0 {
				r.detail = fmt.Sprintf("签到包+%d(至%s)", sum.Checkin,
					time.Unix(sum.ChkExp, 0).Format("01-02"))
			}
		}
		rows = append(rows, r)
	}

	// 报告
	fmt.Println()
	fmt.Println("┌────────────────────┬───────────────┬──────────────┬───────┬───────┬───────┬──────────────────────────────┐")
	fmt.Println("│ UID                │ 昵称          │ 状态         │ 总计  │ 月赠  │ 签到  │ 详情                         │")
	fmt.Println("├────────────────────┼───────────────┼──────────────┼───────┼───────┼───────┼──────────────────────────────┤")
	for _, r := range rows {
		total, month, chk := "-", "-", "-"
		if r.hasRem {
			total = fmt.Sprintf("%d", r.remain)
			month = fmt.Sprintf("%d", r.month)
			if r.checkin > 0 {
				chk = fmt.Sprintf("+%d", r.checkin)
			} else {
				chk = "0"
			}
		}
		fmt.Printf("│ %s │ %s │ %s │ %s │ %s │ %s │ %s │\n",
			pad(trunc(r.uid, 18), 18), pad(trunc(r.nick, 13), 13),
			pad(trunc(r.status, 12), 12), pad(total, 5), pad(month, 5), pad(chk, 5),
			pad(trunc(r.detail, 28), 28))
	}
	fmt.Println("└────────────────────┴───────────────┴──────────────┴───────┴───────┴───────┴──────────────────────────────┘")
	fmt.Println()
	fmt.Printf("📊 总计=%d  签到成功=%d  已签=%d  禁用=%d  未确认=%d  设备异常=%d  失败=%d\n",
		len(rows), okN, alreadyN, disabledN, unconfirmedN, badDevN, failN)
	fmt.Printf("💰 本次确认到账积分=%d\n", okN*100)

	// 签到包过期提醒（7 天内）
	now := time.Now().Unix()
	for _, r := range rows {
		if r.chkExp > 0 && r.checkin > 0 {
			left := (r.chkExp - now) / 86400
			if left <= 7 {
				fmt.Printf("⚠️  %s 的签到包 %d 分将于 %s 到期（剩 %d 天）\n",
					trunc(r.nick, 13), r.checkin,
					time.Unix(r.chkExp, 0).Format("2006-01-02"), left)
			}
		}
	}
}

func isAlready(msg string) bool {
	s := strings.ToLower(msg)
	return strings.Contains(s, "已签到") ||
		strings.Contains(s, "already check") ||
		strings.Contains(s, "already checked")
}

// trunc 按「显示宽度」截断：CJK 字符算 2 列，ASCII 算 1 列，避免截断出半个汉字。
func trunc(s string, n int) string {
	if displayWidth(s) <= n {
		return s
	}
	var b strings.Builder
	w := 0
	for _, r := range s {
		rw := runeWidth(r)
		if w+rw > n-1 { // 留 1 列给省略号
			b.WriteString("…")
			break
		}
		b.WriteRune(r)
		w += rw
	}
	return b.String()
}

func displayWidth(s string) int {
	w := 0
	for _, r := range s {
		w += runeWidth(r)
	}
	return w
}

// runeWidth 估算字符显示宽度：CJK / 全角标点算 2，其余算 1。
func runeWidth(r rune) int {
	switch {
	case r >= 0x1100 && r <= 0x115F, // 谚文字母
		r >= 0x2E80 && r <= 0xA4CF, // CJK 部首、假名、汉字
		r >= 0xAC00 && r <= 0xD7A3, // 谚文音节
		r >= 0xF900 && r <= 0xFAFF, // CJK 兼容汉字
		r >= 0xFE30 && r <= 0xFE6F, // CJK 兼容形式
		r >= 0xFF00 && r <= 0xFF60, // 全角形式
		r >= 0xFFE0 && r <= 0xFFE6,
		r >= 0x20000 && r <= 0x3FFFD: // CJK 扩展
		return 2
	}
	return 1
}

// pad 把 s 填充到指定显示宽度（左侧对齐）。
func pad(s string, n int) string {
	w := displayWidth(s)
	if w >= n {
		return s
	}
	return s + strings.Repeat(" ", n-w)
}

func short(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > 60 {
		return s[:60]
	}
	return s
}
