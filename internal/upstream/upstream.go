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

// doJSON 发送请求并读取响应体。
// TRAE 服务端业务错误会以 HTTP 200 + body 中 code 字段表达（如 code=1001 鉴权失败），
// 因此除 HTTP 状态码外，还需检查 body 里的业务错误码，避免“假成功”。
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
	// 业务错误：body 中出现非成功 code 字段
	var probe struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	}
	if len(raw) > 0 {
		if jerr := json.Unmarshal(raw, &probe); jerr == nil {
			if probe.Code != 0 && probe.Code != 200 {
				msg := strings.TrimSpace(probe.Message)
				if msg == "" {
					msg = fmt.Sprintf("code %d", probe.Code)
				}
				return nil, fmt.Errorf("%s", truncate(msg, 300))
			}
		}
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
// 服务端要求提交 device_id / machine_id，缺失会返回 code 9004 订单参数错误。
func (c *Client) CheckinClaim(a *auth.Auth) error {
	body := map[string]any{}
	if a.DeviceID != "" {
		body["device_id"] = a.DeviceID
	}
	if a.MachineID != "" {
		body["machine_id"] = a.MachineID
	}
	raw, _ := json.Marshal(body)
	req, err := http.NewRequest(http.MethodPost, UgHost+EpCheckinClaim, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	ugHeaders(req, a)
	_, err = c.doJSON(req)
	return err
}

// Usage 积分查询结果。
// Total/Consumed/Remain 来自 usage_summary（权威值）；
// Signin 是“每日签到”奖励包（Work 专属积分）的累计，用于直观展示签到收益。
type Usage struct {
	Total    int64
	Consumed int64
	Remain   int64
	Signin   int64
}

// UserEntUsage 查询积分余额。
func (c *Client) UserEntUsage(a *auth.Auth) (Usage, error) {
	req, err := http.NewRequest(http.MethodPost, UgHost+EpEntUsage, bytes.NewReader([]byte("{}")))
	if err != nil {
		return Usage{}, err
	}
	ugHeaders(req, a)
	data, err := c.doJSON(req)
	if err != nil {
		return Usage{}, err
	}
	var resp struct {
		UsageSummary struct {
			TotalAmount   float64 `json:"total_amount"`
			ConsumedAmount float64 `json:"consumed_amount"`
		} `json:"usage_summary"`
		UserEntitlementPackList []struct {
			EntitlementBaseInfo struct {
				Quota struct {
					CreditsLimit float64 `json:"credits_limit"`
				} `json:"quota"`
				ProductExtra struct {
					PackageExtra struct {
						PackageName string `json:"package_name"`
					} `json:"package_extra"`
				} `json:"product_extra"`
			} `json:"entitlement_base_info"`
			Usage struct {
				CreditsAmount float64 `json:"credits_amount"`
			} `json:"usage"`
		} `json:"user_entitlement_pack_list"`
	}
	if err := json.Unmarshal(data, &resp); err != nil {
		return Usage{}, fmt.Errorf("ent usage parse: %w", err)
	}
	u := Usage{
		Total:    int64(resp.UsageSummary.TotalAmount),
		Consumed: int64(resp.UsageSummary.ConsumedAmount),
	}
	if u.Total > 0 {
		u.Remain = u.Total - u.Consumed
	} else {
		// usage_summary 缺失时回退到逐包累加（不扣已用，尽力而为）
		for _, p := range resp.UserEntitlementPackList {
			l := int64(p.EntitlementBaseInfo.Quota.CreditsLimit)
			if l <= 0 {
				continue
			}
			u.Remain += l
		}
	}
	// 累计“每日签到”奖励包（Work 专属积分）
	for _, p := range resp.UserEntitlementPackList {
		if p.EntitlementBaseInfo.ProductExtra.PackageExtra.PackageName != "签到奖励" {
			continue
		}
		u.Signin += int64(p.EntitlementBaseInfo.Quota.CreditsLimit)
	}
	return u, nil
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
	if a.MachineID != "" {
		req.Header.Set("X-Machine-Id", a.MachineID)
	}
}

func truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	// 按 rune 截断，避免切断 UTF-8 多字节字符导致非法输出
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}
