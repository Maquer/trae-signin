#!/usr/bin/env bash
# push-to-github.sh — 一键推送到 GitHub
# 用法：将 trae-signin 文件夹复制到本地后，在此目录下执行本脚本
set -e

REPO_NAME="trae-signin"
GITHUB_USER="${GITHUB_USER:-}"

if [ -z "$GITHUB_USER" ]; then
    read -rp "请输入 GitHub 用户名: " GITHUB_USER
fi

echo "📦 创建 GitHub 仓库 $GITHUB_USER/$REPO_NAME ..."
gh repo create "$GITHUB_USER/$REPO_NAME" --public --source=. --push || {
    echo "仓库可能已存在，尝试直接推送..."
}

echo ""
echo "🚀 推送到 GitHub..."
git remote add origin "https://github.com/$GITHUB_USER/$REPO_NAME.git" 2>/dev/null || true
git branch -M main
git push -u origin main

echo ""
echo "✅ 完成！仓库地址: https://github.com/$GITHUB_USER/$REPO_NAME"
