// Package upstream 封装 TRAE SOLO 签到、积分查询、Token 刷新等上游 API。
package upstream

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"trae-signin/internal/auth"
)

const (
	UgHost         = "https://api.trae.cn"
	OAuthHost      = "https://api.trae.com.cn"
	ClientID       = "en1oxy7wnw8j9n"
	IdeVersion     = "0.1.43"
	IdeVersionCode = "20260716"

	EpExchange      = "/cloudide/api/v3/trae/oauth/ExchangeToken"
	EpCheckinStatus = "/trae/api/v2/ug/checkin_credits/status"
	EpCheckinClaim  = "/trae/api/v2/ug/checkin_credits/claim"
	EpEntUsage      = "/trae/api/v2/pay/ide_user_ent_usage"
)

var clientUA = "Trae/" + IdeVersion

type Client struct {
	HTTP *http.Client
}

func New() *Client {
	tr := &http.Transport{
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 20,
		IdleConnTimeout:     90 * time.Second,
	}
	return &Client{
		HTTP: &http.Client{Timeout: 60 * time.Second, Transport: tr},
	}
}

func (c *Client) doJSON(req *http.Request) (json.RawMessage, error) {
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("http %d: %s", resp.StatusCode, truncate(string(raw), 200))
	}
	return raw, nil
}

// RefreshToken 通过 ExchangeToken 强制刷新 access token。
func (c *Client) RefreshToken(a *auth.Auth) error {
	a.Lock()
	defer a.Unlock()

	if strings.TrimSpace(a.RefreshToken) == "" {
		return fmt.Errorf("no refreshToken")
	}
	host := a.ApiHost
	if host == "" {
		host = OAuthHost
	}
	body := map[string]any{
		"ClientID":     ClientID,
		"RefreshToken": a.RefreshToken,
		"ClientSecret": "-",
		"UserID":       "",
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequest(http.MethodPost, host+EpExchange, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", clientUA)

	data, err := c.doJSON(req)
	if err != nil {
		return err
	}
	var resp struct {
		Result struct {
			Token               string `json:"Token"`
			TokenExpireAt       int64  `json:"TokenExpireAt"`
			TokenExpireDuration int64  `json:"TokenExpireDuration"`
			RefreshToken        string `json:"RefreshToken"`
		} `json:"Result"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return fmt.Errorf("exchange parse: %w", err)
	}
	if resp.Result.Token == "" {
		return fmt.Errorf("refresh_failed: no token — re-login required")
	}
	a.AccessToken = resp.Result.Token
	if resp.Result.RefreshToken != "" {
		a.RefreshToken = resp.Result.RefreshToken
	}
	if resp.Result.TokenExpireAt > 0 {
		exp := resp.Result.TokenExpireAt
		if exp > 1e12 {
			exp /= 1000
		}
		a.ExpiresAt = exp
	} else if resp.Result.TokenExpireDuration > 0 {
		a.ExpiresAt = time.Now().Add(time.Duration(resp.Result.TokenExpireDuration) * time.Second).Unix()
	}
	return nil
}

// CheckinStatus 查询签到状态。
func (c *Client) CheckinStatus(a *auth.Auth) (checkedIn bool, credits int64, enable bool, err error) {
	req, err := http.NewRequest(http.MethodPost, UgHost+EpCheckinStatus, bytes.NewReader([]byte("{}")))
	if err != nil {
		return false, 0, false, err
	}
	ugHeaders(req, a)
	data, err := c.doJSON(req)
	if err != nil {
		return false, 0, false, err
	}
	var resp struct {
		CheckedIn bool  `json:"checked_in"`
		Credits   int64 `json:"credits"`
		Enable    bool  `json:"enable"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return false, 0, false, fmt.Errorf("checkin status parse: %w", err)
	}
	return resp.CheckedIn, resp.Credits, resp.Enable, nil
}

// CheckinClaim 执行签到。
func (c *Client) CheckinClaim(a *auth.Auth) error {
	req, err := http.NewRequest(http.MethodPost, UgHost+EpCheckinClaim, bytes.NewReader([]byte("{}")))
	if err != nil {
		return err
	}
	ugHeaders(req, a)
	_, err = c.doJSON(req)
	return err
}

// CreditPack 单个积分包的摘要。
type CreditPack struct {
	Credits   int64  // 该包额度
	Desc      string // 展示名（display_desc / group_name 兜底）
	Expire    int64  // 过期 Unix 秒，0 表示无
	IsCheckin bool   // 是否签到奖励包
}

// CreditSummary 账号积分的完整拆分。
type CreditSummary struct {
	Total    int64        // 合计
	Month    int64        // 每月登录赠送额度
	Checkin  int64        // 签到奖励额度
	MonthExp int64        // 月赠过期时间
	ChkExp   int64        // 签到包过期时间
	Packs    []CreditPack // 明细
}

// UserEntUsage 查询积分余额（合计）。保留向后兼容。
func (c *Client) UserEntUsage(a *auth.Auth) (remain int64, err error) {
	s, err := c.UserCreditSummary(a)
	if err != nil {
		return 0, err
	}
	return s.Total, nil
}

// UserCreditSummary 查询积分余额并拆分签到包 / 月赠包。
func (c *Client) UserCreditSummary(a *auth.Auth) (*CreditSummary, error) {
	req, err := http.NewRequest(http.MethodPost, UgHost+EpEntUsage, bytes.NewReader([]byte("{}")))
	if err != nil {
		return nil, err
	}
	ugHeaders(req, a)
	data, err := c.doJSON(req)
	if err != nil {
		return nil, err
	}
	var resp struct {
		UserEntitlementPackList []struct {
			DisplayDesc         string `json:"display_desc"`
			GroupName           string `json:"group_name"`
			GroupType           int64  `json:"group_type"`
			ExpireTime          int64  `json:"expire_time"`
			EntitlementBaseInfo struct {
				EntitlementID string `json:"entitlement_id"`
				Quota         struct {
					CreditsLimit int64 `json:"credits_limit"`
				} `json:"quota"`
			} `json:"entitlement_base_info"`
		} `json:"user_entitlement_pack_list"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, fmt.Errorf("ent usage parse: %w", err)
	}

	s := &CreditSummary{}
	for _, p := range resp.UserEntitlementPackList {
		credits := p.EntitlementBaseInfo.Quota.CreditsLimit
		desc := p.DisplayDesc
		if desc == "" {
			desc = p.GroupName
		}
		isChk := p.GroupType == 1 ||
			strings.Contains(p.GroupName, "签到") ||
			strings.Contains(desc, "签到") ||
			strings.Contains(p.EntitlementBaseInfo.EntitlementID, "checkin")

		s.Total += credits
		if credits <= 0 { // 免费权益壳，无额度，不计入拆分
			continue
		}
		s.Packs = append(s.Packs, CreditPack{
			Credits: credits, Desc: desc, Expire: p.ExpireTime, IsCheckin: isChk,
		})
		if isChk {
			s.Checkin += credits
			if p.ExpireTime > s.ChkExp {
				s.ChkExp = p.ExpireTime
			}
		} else {
			s.Month += credits
			if p.ExpireTime > s.MonthExp {
				s.MonthExp = p.ExpireTime
			}
		}
	}
	return s, nil
}

func ugHeaders(req *http.Request, a *auth.Auth) {
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", clientUA)
	req.Header.Set("Authorization", "Cloud-IDE-JWT "+a.JWT())
	req.Header.Set("X-User-Region", "CN")
	if a.DeviceID != "" {
		req.Header.Set("X-Device-Id", a.DeviceID)
	}
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		return s[:n]
	}
	return s
}
