#!/bin/bash
# 개발용: 릴리스 빌드 mobius를 /usr/local/bin에 링크
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
sudo mkdir -p /usr/local/bin
sudo ln -sf "$(pwd)/.build/release/mobius" /usr/local/bin/mobius
echo "OK: $(which mobius)"
