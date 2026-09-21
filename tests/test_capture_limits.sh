#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp"
unset XDG_STATE_HOME
umask 022

mkdir -p "$tmp/bin"
cat >"$tmp/bin/wl-paste" <<'EOF'
#!/bin/bash
if [[ ${1:-} == --list-types ]]; then
  printf 'text/plain\n'
  exit 0
fi
exit 0
EOF
chmod +x "$tmp/bin/wl-paste"
export PATH="$tmp/bin:$PATH"

TEXT_MAX=1048576
IMAGE_MAX=10485760
capture="$root/capture.sh"

out="$(printf 'hello clipvault' | "$capture" text)"
[[ $out == '{"type":"text","text":"hello clipvault"}' ]]

python3 -c "import sys; sys.stdout.write('a' * $TEXT_MAX)" | "$capture" text >"$tmp/limit.json"
python3 -c "
import json, pathlib
p = pathlib.Path('$tmp/limit.json')
data = json.loads(p.read_text())
assert data['type'] == 'text'
assert data['text'] == 'a' * $TEXT_MAX
"

python3 -c "import sys; sys.stdout.write('a' * ($TEXT_MAX + 1))" | "$capture" text >"$tmp/over.json" || true
[[ ! -s $tmp/over.json ]]

img_dir="$tmp/.local/state/omarchy/clipboard-images"
printf 'fake-png' | "$capture" image/png >"$tmp/img.json"
[[ -s $tmp/img.json ]]
count_before=$(find "$img_dir" -type f ! -name 'clipboard.*' | wc -l)
[[ $count_before -ge 1 ]]

python3 -c "import sys; sys.stdout.buffer.write(b'x' * ($IMAGE_MAX + 1))" | "$capture" image/png >"$tmp/over-img.json" || true
[[ ! -s $tmp/over-img.json ]]
count_after=$(find "$img_dir" -type f ! -name 'clipboard.*' | wc -l)
[[ $count_after -eq $count_before ]]

echo "ok  capture.sh drops oversized text and images"
