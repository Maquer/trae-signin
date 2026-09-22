// Package auth 解析 TRAE SOLO auth 文件（嵌套形：auth + account），
// 提供原子写回。
package auth

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// Auth 归一化后的账号凭证。
type Auth struct {
	mu sync.RWMutex

	AccessToken  string
	RefreshToken string
	ExpiresAt    int64  // Unix 秒
	Domain       string
	ApiHost      string
	MachineID    string
	DeviceID     string
	UID          string
	EnterpriseID string
	Nickname     string
	FilePath     string
}

func (a *Auth) Lock()   { a.mu.Lock() }
func (a *Auth) Unlock() { a.mu.Unlock() }
func (a *Auth) RLock()  { a.mu.RLock() }
func (a *Auth) RUnlock() { a.mu.RUnlock() }

func (a *Auth) JWT() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.AccessToken
}

func (a *Auth) RefreshTokenValue() string {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.RefreshToken
}

func (a *Auth) NeedsRefresh(within time.Duration) bool {
	a.mu.RLock()
	defer a.mu.RUnlock()
	return a.NeedsRefreshLocked(within)
}

func (a *Auth) NeedsRefreshLocked(within time.Duration) bool {
	if a.ExpiresAt <= 0 {
		return true
	}
	return time.Now().Add(within).Unix() >= a.ExpiresAt
}

func parseNested(raw []byte) (*Auth, error) {
	var n struct {
		Auth struct {
			AccessToken  string `json:"accessToken"`
			RefreshToken string `json:"refreshToken"`
			ExpiresAt    int64  `json:"expiresAt"`
			Domain       string `json:"domain"`
			ApiHost      string `json:"apiHost"`
			MachineID    string `json:"machineId"`
			DeviceID     string `json:"deviceId"`
		} `json:"auth"`
		Account struct {
			UID          string `json:"uid"`
			EnterpriseID string `json:"enterpriseId"`
			Nickname     string `json:"nickname"`
		} `json:"account"`
	}
	if err := json.Unmarshal(raw, &n); err != nil {
		return nil, fmt.Errorf("storage_parse_error: %w", err)
	}
	return &Auth{
		AccessToken:  n.Auth.AccessToken,
		RefreshToken: n.Auth.RefreshToken,
		ExpiresAt:    n.Auth.ExpiresAt,
		Domain:       n.Auth.Domain,
		ApiHost:      n.Auth.ApiHost,
		MachineID:    n.Auth.MachineID,
		DeviceID:     n.Auth.DeviceID,
		UID:          n.Account.UID,
		EnterpriseID: n.Account.EnterpriseID,
		Nickname:     n.Account.Nickname,
	}, nil
}

func parseFlat(raw []byte) (*Auth, error) {
	var f struct {
		AccessToken  string `json:"accessToken"`
		RefreshToken string `json:"refreshToken"`
		ExpiresAt    int64  `json:"expiresAt"`
		Domain       string `json:"domain"`
		ApiHost      string `json:"apiHost"`
		MachineID    string `json:"machineId"`
		DeviceID     string `json:"deviceId"`
		UID          string `json:"uid"`
		EnterpriseID string `json:"enterpriseId"`
		Nickname     string `json:"nickname"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("storage_parse_error: %w", err)
	}
	return &Auth{
		AccessToken:  f.AccessToken,
		RefreshToken: f.RefreshToken,
		ExpiresAt:    f.ExpiresAt,
		Domain:       f.Domain,
		ApiHost:      f.ApiHost,
		MachineID:    f.MachineID,
		DeviceID:     f.DeviceID,
		UID:          f.UID,
		EnterpriseID: f.EnterpriseID,
		Nickname:     f.Nickname,
	}, nil
}

func Parse(raw []byte) (*Auth, error) {
	if len(raw) == 0 {
		return nil, fmt.Errorf("empty auth storage")
	}
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(raw, &probe); err != nil {
		return nil, fmt.Errorf("storage_parse_error: %w", err)
	}
	var (
		a   *Auth
		err error
	)
	if _, nested := probe["auth"]; nested {
		a, err = parseNested(raw)
	} else {
		a, err = parseFlat(raw)
	}
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(a.AccessToken) == "" {
		return nil, fmt.Errorf("parse_error: missing accessToken")
	}
	return a, nil
}

func (a *Auth) SaveAtomic() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.saveAtomicLocked()
}

func (a *Auth) saveAtomicLocked() error {
	if a.FilePath == "" {
		return fmt.Errorf("no FilePath set")
	}
	doc := map[string]any{
		"auth": map[string]any{
			"accessToken":  a.AccessToken,
			"refreshToken": a.RefreshToken,
			"expiresAt":    a.ExpiresAt,
			"domain":       a.Domain,
			"apiHost":      a.ApiHost,
			"machineId":    a.MachineID,
			"deviceId":     a.DeviceID,
		},
		"account": map[string]any{
			"uid":          a.UID,
			"enterpriseId": a.EnterpriseID,
			"nickname":     a.Nickname,
		},
	}
	raw, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	tmp := a.FilePath + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, a.FilePath)
}
