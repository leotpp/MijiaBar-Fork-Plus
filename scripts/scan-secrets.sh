#!/bin/bash
# 推送前检查；只打印路径，不回显疑似凭据。
# EXTRA_PATTERNS 可追加 ERE 模式（用 | 分隔）。
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re
import subprocess
import sys
from pathlib import Path

pattern = re.compile(rb'192\.168\.[0-9]+\.[0-9]+|"token"\s*:\s*"[0-9a-fA-F]{32}"|"(?:ssecurity|serviceToken|passToken|cUserId)"\s*:\s*"([^"\s]{16,})"|blt\.[0-9]+\.[A-Za-z0-9_]+')
failed = False
for raw in subprocess.check_output(['git', 'ls-files', '-z']).split(b'\0'):
    if not raw:
        continue
    path = Path(raw.decode())
    if not path.is_file():
        continue
    for match in pattern.finditer(path.read_bytes()):
        # 既有测试的固定合成值；只豁免该文件里的这个值。
        if str(path) == 'Tests/MijiaCoreTests/SessionRefreshTests.swift' and match.group(1) == b'synthetic-rotated':
            continue
        print(path)
        failed = True
        break
sys.exit(1 if failed else 0)
PY
if [ -n "${EXTRA_PATTERNS:-}" ]; then
  if git grep -lE "$EXTRA_PATTERNS" -- . ':!scripts/scan-secrets.sh'; then exit 1
  else result=$?; [ "$result" -eq 1 ] || exit "$result"; fi
fi
echo "✅ 未发现凭据 / 局域网 IP / 本机设备 ID"
