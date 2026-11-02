#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp"
unset XDG_STATE_HOME
umask 022
export IMAGE_STORE_MAX=80

state="$tmp/.local/state/omarchy"
img_dir="$state/clipboard-images"
history="$state/clipboard-history.json"
prune="$root/prune-images.sh"
capture="$root/capture.sh"
save="$root/save-history.sh"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/wl-paste" <<'EOF'
#!/bin/bash
if [[ ${1:-} == --list-types ]]; then
  printf 'text/plain\n'
  exit 0
fi
exit 0
EOF
chmod +x "$tmp/bin/wl-paste" "$prune" "$capture" "$save"
export PATH="$tmp/bin:$PATH"

hash_name() {
  printf '%s' "$1" | sha256sum | awk '{print $1 ".png"}'
}

managed_count() {
  find "$img_dir" -maxdepth 1 -type f -name '????????????????????????????????????????????????????????????????.*' 2>/dev/null | wc -l
}

managed_bytes() {
  find "$img_dir" -maxdepth 1 -type f -name '????????????????????????????????????????????????????????????????.*' -printf '%s\n' 2>/dev/null \
    | awk '{s+=$1} END {print s+0}'
}

mkdir -p "$img_dir"
chmod 700 "$img_dir"
printf '[]\n' >"$history"

# Distinct captures persist, then budget drops oldest managed files.
mkpng="$root/tests/make_png.py"
for i in 1 2 3 4 5 6; do
  python3 "$mkpng" 1 1 "$i" 0 0 | "$capture" image/png >/dev/null
done
bytes=$(managed_bytes)
count=$(managed_count)
[[ $bytes -le $IMAGE_STORE_MAX ]]
[[ $count -ge 1 ]]
[[ $count -lt 6 ]]

# --remove only unlinks a validated plugin-created file in IMAGE_DIR.
python3 "$mkpng" 1 1 9 9 9 >"$tmp/keep.png"
"$capture" image/png <"$tmp/keep.png" >/dev/null
keep_name="$(sha256sum "$tmp/keep.png" | awk '{print $1 ".png"}')"
keep_file="$img_dir/$keep_name"
[[ -f $keep_file ]]

outside="$tmp/outside-secret"
printf 'do-not-delete\n' >"$outside"
"$prune" --remove "$outside" "/etc/passwd" "../../.ssh/id_rsa" "not-a-hash.png"
[[ -f $outside ]]
[[ -f $keep_file ]]

"$prune" --remove "$keep_name"
[[ ! -f $keep_file ]]
[[ -f $outside ]]

# Symlink whose name looks managed must not follow into a file outside IMAGE_DIR.
link_name="$(printf '%s' 'symlink-target' | sha256sum | awk '{print $1 ".png"}')"
ln -s "$outside" "$img_dir/$link_name"
"$prune" --remove "$link_name"
[[ -L $img_dir/$link_name ]]
[[ -f $outside ]]
rm -f "$img_dir/$link_name"

# Sweep deletes unreferenced managed files and leaves non-managed names alone.
old_name="$(printf '%s' 'old-orphan' | sha256sum | awk '{print $1 ".png"}')"
printf 'orphan\n' >"$img_dir/$old_name"
# Backdate so grace does not keep it.
touch -d '10 seconds ago' "$img_dir/$old_name"
printf 'leave-me\n' >"$img_dir/notes.txt"
live_name="$(printf '%s' 'still-in-history' | sha256sum | awk '{print $1 ".png"}')"
printf 'live\n' >"$img_dir/$live_name"
python3 - "$history" "$img_dir/$live_name" <<'PY'
import json, sys
json.dump([{"type": "image", "path": sys.argv[2], "mime": "image/png"}], open(sys.argv[1], "w"))
PY
"$prune" --sweep --grace-seconds 2
[[ ! -f $img_dir/$old_name ]]
[[ -f $img_dir/$live_name ]]
[[ -f $img_dir/notes.txt ]]
[[ -f $outside ]]

# save-history.sh sweep after a clear must drop unmanaged-history image files.
printf 'stale\n' >"$img_dir/$old_name"
touch -d '10 seconds ago' "$img_dir/$old_name"
printf '[]\n' | "$save"
[[ ! -f $img_dir/$old_name ]]
[[ -f $img_dir/notes.txt ]]

# Invalid history JSON must not treat every image as unreferenced.
printf 'keep-invalid-history\n' >"$img_dir/$live_name"
touch -d '10 seconds ago' "$img_dir/$live_name"
printf '{"nope":true}\n' | "$save"
[[ -f $img_dir/$live_name ]]

# Traversal and foreign paths in history must never delete those files.
evil_name="$(printf '%s' 'evil-name' | sha256sum | awk '{print $1 ".png"}')"
printf 'still-here\n' >"$tmp/$evil_name"
python3 - "$history" "$tmp/$evil_name" "$img_dir/../../$evil_name" <<'PY'
import json, sys
json.dump([
    {"type": "image", "path": sys.argv[2], "mime": "image/png"},
    {"type": "image", "path": sys.argv[3], "mime": "image/png"},
], open(sys.argv[1], "w"))
PY
printf '%s\n' "$(cat "$history")" | "$save"
[[ -f $tmp/$evil_name ]]
[[ -f $outside ]]

# A file entry's managed preview copy counts as referenced by the sweep.
prev_name="$(printf '%s' 'file-preview' | sha256sum | awk '{print $1 ".png"}')"
printf 'preview\n' >"$img_dir/$prev_name"
touch -d '10 seconds ago' "$img_dir/$prev_name"
python3 - "$history" "$img_dir/$prev_name" <<'PY'
import json, sys
json.dump([{"type": "text", "text": "file:///srv/a.png", "preview": sys.argv[2]}], open(sys.argv[1], "w"))
PY
printf '%s\n' "$(cat "$history")" | "$save"
[[ -f $img_dir/$prev_name ]]
printf '[]\n' | "$save"
[[ ! -f $img_dir/$prev_name ]]

echo "ok  image store budget and managed-file cleanup"
