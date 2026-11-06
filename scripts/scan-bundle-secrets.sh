#!/bin/bash
# 扫描完整产物；只输出路径，不回显疑似凭据。
set -euo pipefail
[ "$#" -eq 1 ] && [ -d "$1" ] || { echo "Usage: $0 <App path>" >&2; exit 2; }
python3 - "$1" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
patterns = [
    rb'"(?:ssecurity|serviceToken|passToken|cUserId)"\s*:\s*"[^"\s]{16,}"',
    rb'"token"\s*:\s*"[0-9a-fA-F]{32}"',
    rb'blt\.[0-9]+\.[A-Za-z0-9_]+',
]
secret = re.compile(b'|'.join(patterns))
lan_ip = re.compile(rb'192\.168\.[0-9]+\.[0-9]+')
state_names = {'session', 'session.json', 'devices.json', 'prefs.json', 'agent.json', 'spec-index.json'}
# 即使缓存改名，也拦截序列化的会话与设备列表；代码中的单个 key 不算状态。
state = re.compile(rb'"userId"\s*:\s*"[^"\s]+"[\s\S]{0,4096}"(?:ssecurity|serviceToken)"\s*:\s*"|"devices"\s*:\s*\[\s*\{\s*"(?:did|name|model)"\s*:')
failed = False

def walk_error(error):
    raise error

try:
    for directory, dirs, files in os.walk(root, onerror=walk_error):
        for name in files:
            path = Path(directory) / name
            relative = path.relative_to(root)
            data = path.read_bytes()
            local_state = name.lower() in state_names or path.stem.lower() == 'session' or ('specs' in relative.parts and path.suffix.lower() == '.json')
            if data.lstrip().startswith(b'{'):
                try:
                    value = json.loads(data)
                    keys = value.keys() if isinstance(value, dict) else ()
                    local_state |= any(set(fields) <= set(keys) for fields in [
                        ('userId', 'ssecurity', 'serviceToken'), ('homes', 'devices', 'updated'),
                        ('devices', 'region'), ('mode', 'allowlist', 'confirmWrites'),
                    ])
                except (ValueError, UnicodeError):
                    pass
            # 第三方 vendored go2rtc 经 SHA-256 校验下载，内置文档含示例地址，仅豁免此路径的局域网 IP。
            has_lan_ip = relative != Path('Contents/Resources/bin/go2rtc') and lan_ip.search(data)
            if local_state or secret.search(data) or state.search(data) or has_lan_ip:
                print(path)
                failed = True
except OSError as error:
    print(error.filename or root, file=sys.stderr)
    sys.exit(2)
sys.exit(1 if failed else 0)
PY
