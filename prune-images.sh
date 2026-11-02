#!/bin/bash
# Delete only plugin-created clipboard images under the canonical image
# directory. Callers pass basenames (or --sweep/--budget); clipboard-supplied
# paths are never used as rm targets.
#
# Managed names: <sha256>.<ext> written by capture.sh. Symlinks, traversal,
# and any file outside IMAGE_DIR are ignored.
set -euo pipefail
umask 077

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
IMAGE_DIR="$STATE_DIR/clipboard-images"
HISTORY="$STATE_DIR/clipboard-history.json"
IMAGE_STORE_MAX="${IMAGE_STORE_MAX:-$((64 * 1024 * 1024))}"
MANAGED_RE='^[0-9a-f]{64}\.(png|jpg|jpeg|webp|gif|bmp|tiff)$'

is_managed_name() {
  local name="${1:-}"
  [[ -n $name && $name != */* && $name =~ $MANAGED_RE ]]
}

# Construct IMAGE_DIR/<name> and unlink only a regular, non-symlink file there.
rm_managed() {
  local name="${1:-}"
  is_managed_name "$name" || return 0
  [[ -n ${IMAGE_DIR:-} && -d $IMAGE_DIR && ! -L $IMAGE_DIR ]] || return 0

  local target="$IMAGE_DIR/$name"
  local parent="${target%/*}"
  [[ $parent == "$IMAGE_DIR" ]] || return 0
  [[ -e $target && -f $target && ! -L $target ]] || return 0

  rm -f -- "$target"
}

referenced_names() {
  [[ -f $HISTORY ]] || return 0
  # Invalid history must not look like "nothing is referenced".
  jq -e 'type=="array"' "$HISTORY" >/dev/null 2>&1 || return 1
  local path name
  while IFS= read -r path; do
    name="${path##*/}"
    if is_managed_name "$name"; then
      printf '%s\n' "$name"
    fi
  done < <(jq -r '.[] | select(type=="object")
    | (select(.type=="image") | .path), (select(.type=="text") | .preview)
    | select(type=="string")' "$HISTORY" 2>/dev/null)
}

budget_prune() {
  local keep_name="${1:-}"
  [[ -n ${IMAGE_DIR:-} && -d $IMAGE_DIR && ! -L $IMAGE_DIR ]] || return 0
  if ! [[ $IMAGE_STORE_MAX =~ ^[0-9]+$ ]]; then
    IMAGE_STORE_MAX=$((64 * 1024 * 1024))
  fi

  local list total=0
  list=$(mktemp) || return 0

  shopt -s nullglob
  local f base size mtime
  for f in "$IMAGE_DIR"/*; do
    base="${f##*/}"
    is_managed_name "$base" || continue
    [[ -f $f && ! -L $f ]] || continue
    size=$(stat -c '%s' -- "$f" 2>/dev/null) || continue
    mtime=$(stat -c '%Y' -- "$f" 2>/dev/null) || continue
    printf '%s %s %s\n' "$mtime" "$size" "$base" >>"$list"
    total=$((total + size))
  done

  if (( total <= IMAGE_STORE_MAX )); then
    rm -f "$list"
    return 0
  fi

  # Oldest first. Never delete the file we just persisted.
  while read -r mtime size base; do
    if (( total <= IMAGE_STORE_MAX )); then
      break
    fi
    [[ -n $base && $base != "$keep_name" ]] || continue
    rm_managed "$base"
    total=$((total - size))
  done < <(sort -n -k1,1 -k3,3 "$list")
  rm -f "$list"
}

sweep_unreferenced() {
  local grace="${1:-0}"
  [[ -n ${IMAGE_DIR:-} && -d $IMAGE_DIR && ! -L $IMAGE_DIR ]] || return 0
  if ! [[ $grace =~ ^[0-9]+$ ]]; then
    grace=0
  fi

  declare -A keep=()
  local name refs
  if ! refs=$(referenced_names); then
    return 0
  fi
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    keep["$name"]=1
  done <<< "$refs"

  local now
  now=$(date +%s)
  shopt -s nullglob
  local f base mtime
  for f in "$IMAGE_DIR"/*; do
    base="${f##*/}"
    is_managed_name "$base" || continue
    [[ -f $f && ! -L $f ]] || continue
    [[ -z ${keep[$base]+x} ]] || continue
    if (( grace > 0 )); then
      mtime=$(stat -c '%Y' -- "$f" 2>/dev/null) || continue
      if (( now - mtime < grace )); then
        continue
      fi
    fi
    rm_managed "$base"
  done
}

mode=""
grace=0
keep=""
remove_names=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remove)
      mode="remove"
      shift
      remove_names+=("$@")
      break
      ;;
    --sweep)
      mode="sweep"
      shift
      ;;
    --budget)
      mode="budget"
      shift
      if [[ $# -gt 0 && $1 != --* ]]; then
        keep="$1"
        shift
      fi
      ;;
    --grace-seconds)
      grace="${2:-0}"
      shift 2
      ;;
    *)
      exit 1
      ;;
  esac
done

case "$mode" in
  remove)
    for name in "${remove_names[@]}"; do
      rm_managed "$name"
    done
    ;;
  sweep)
    sweep_unreferenced "$grace"
    budget_prune ""
    ;;
  budget)
    budget_prune "$keep"
    ;;
  *)
    exit 1
    ;;
esac
