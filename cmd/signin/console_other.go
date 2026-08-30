//go:build !windows

package main

// Linux / macOS 等平台无需设置 Windows 控制台代码页。
func init() {}
