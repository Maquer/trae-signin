//go:build windows

package main

import "syscall"

func init() {
	// Windows 控制台默认 GBK 代码页，改为 UTF-8 避免中文乱码。
	// 仅 Windows 编译（syscall.NewLazyDLL 是 Windows 专用 API）。
	mod := syscall.NewLazyDLL("kernel32.dll")
	proc := mod.NewProc("SetConsoleOutputCP")
	proc.Call(65001)
}
