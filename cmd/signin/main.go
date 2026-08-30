// signin — TRAE 纯签到工具：遍历 auths/trae-*.json 全部账号，
// 自动刷新过期 token，逐个签到并查询积分。
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	"trae-signin/internal/auth"
	"trae-signin/internal/upstream"
)

type row struct {
	uid     string
	nick    string
	status  string
	detail  string
	remain  int64
	signin  int64
	hasRem  bool
	hasSign bool
}

func main() {
	dir := "auths"
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}
	files, err := filepath.Glob(filepath.Join(dir, "trae-*.json"))
	if err != nil || len(files) == 0 {
		fmt.Fprintf(os.Stderr, "❌ 在 %s 中没有找到 trae-*.json 凭证文件\n", dir)
		if runtime.GOOS == "windows" {
			fmt.Fprintf(os.Stderr, "   请先运行 login.ps1 登录账号\n")
		} else {
			fmt.Fprintf(os.Stderr, "   请先运行 login.sh 登录账号\n")
		}
		os.Exit(1)
	}
	sort.Strings(files)
	up := upstream.New()

	var rows []row
	okN, alreadyN, failN, disabledN := 0, 0, 0, 0

	for _, f := range files {
		r := row{}
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
			if err := a.SaveAtomic(); err != nil {
				fmt.Printf("   ⚠️ 凭证保存失败: %v\n", err)
			} else {
				fmt.Printf("   ✅ token 刷新成功\n")
			}
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
			if err := claimWithRetry(up, a); err != nil {
				r.status = "FAIL"
				r.detail = short(err.Error())
				failN++
			} else {
				r.status = "✅ OK"
				okN++
			}
		}

		// 查积分
		if u, qerr := up.UserEntUsage(a); qerr == nil {
			r.remain, r.hasRem = u.Remain, true
			r.signin, r.hasSign = u.Signin, true
		}
		rows = append(rows, r)
	}

	// 报告
	fmt.Println()
	fmt.Println("┌──────────────────────────────────────┬───────────────┬──────────────┬──────────────┬──────────┬──────────────────────────────────────┐")
	fmt.Println("│ UID                                  │ 昵称          │ 状态         │ 签到奖励     │ 总剩余   │ 详情                                 │")
	fmt.Println("├──────────────────────────────────────┼───────────────┼──────────────┼──────────────┼──────────┼──────────────────────────────────────┤")
	var totalRemain, totalSign int64
	for _, r := range rows {
		remain := "-"
		if r.hasRem {
			remain = fmt.Sprintf("%d", r.remain)
			totalRemain += r.remain
		}
		signin := "-"
		if r.hasSign {
			signin = fmt.Sprintf("%d", r.signin)
			totalSign += r.signin
		}
		fmt.Printf("│ %-36s │ %-13s │ %-12s │ %-12s │ %-8s │ %-36s │\n",
			trunc(r.uid, 36), trunc(r.nick, 13), r.status, signin, remain, trunc(r.detail, 36))
	}
	fmt.Println("└──────────────────────────────────────┴───────────────┴──────────────┴──────────────┴──────────┴──────────────────────────────────────┘")
	fmt.Println()
	fmt.Printf("📊 总计=%d  签到成功=%d  已签=%d  禁用=%d  失败=%d  累计签到奖励=%d  总剩余=%d\n",
		len(rows), okN, alreadyN, disabledN, failN, totalSign, totalRemain)
}

func isAlready(msg string) bool {
	s := strings.ToLower(msg)
	return strings.Contains(s, "已签到") ||
		strings.Contains(s, "already check") ||
		strings.Contains(s, "already checked")
}

// claimWithRetry 执行签到；遇到服务端限流（参与用户太多）时自动重试。
func claimWithRetry(up *upstream.Client, a *auth.Auth) error {
	const (
		retries = 3
		wait    = 30 * time.Second
	)
	var lastErr error
	for i := 0; i <= retries; i++ {
		if i > 0 {
			fmt.Printf("   ⏳ 签到被限流，%.0f 秒后重试 (%d/%d)...\n", wait.Seconds(), i, retries)
			time.Sleep(wait)
		}
		lastErr = up.CheckinClaim(a)
		if lastErr == nil {
			return nil
		}
		msg := strings.ToLower(lastErr.Error())
		if !strings.Contains(msg, "参与用户太多") &&
			!strings.Contains(msg, "请稍后再试") &&
			!strings.Contains(msg, "too many") {
			return lastErr // 非限流错误，立即返回
		}
	}
	return lastErr
}

func trunc(s string, n int) string {
	// 按 rune 截断，避免切断 UTF-8 中文导致输出乱码/非法字节
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

func short(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	r := []rune(s)
	if len(r) > 60 {
		return string(r[:60])
	}
	return s
}
