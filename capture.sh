#!/bin/bash

# Captures the current clipboard as a JSON entry on stdout. In watch mode,
# wl-paste invokes this with the payload on stdin and the mime as $1. Without
# arguments, it snapshots the current selection itself.
#
# Oversize clips are dropped, not truncated. Caps apply before text is decoded
# or JSON-encoded and before an image is persisted.

set -o pipefail
umask 077

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
IMAGE_DIR="$STATE_DIR/clipboard-images"
HISTORY="$STATE_DIR/clipboard-history.json"
TEXT_MAX=1048576
IMAGE_MAX=10485760
JSON_MAX=2097152
TYPES_MAX=4096
INGEST_TIMEOUT=2

mkdir -p "$IMAGE_DIR"
chmod 700 "$IMAGE_DIR" 2>/dev/null || true
if [[ ! -f $HISTORY ]]; then
  printf '[]\n' >"$HISTORY"
fi
chmod 600 "$HISTORY" 2>/dev/null || true

read_capped() {
  local dest="$1" max="$2"
  if ! timeout "$INGEST_TIMEOUT"s head -c "$((max + 1))" >"$dest"; then
    rm -f "$dest"
    return 1
  fi
  local size
  size=$(stat -c '%s' -- "$dest" 2>/dev/null) || size=0
  if (( size == 0 || size > max )); then
    rm -f "$dest"
    return 1
  fi
  return 0
}

types_tmp=$(mktemp --tmpdir="$STATE_DIR" clipboard-types.XXXXXX) || exit 0
if ! timeout "$INGEST_TIMEOUT"s wl-paste --list-types 2>/dev/null | head -c "$((TYPES_MAX + 1))" >"$types_tmp"; then
  rm -f "$types_tmp"
  types=""
else
  types_size=$(stat -c '%s' -- "$types_tmp" 2>/dev/null) || types_size=0
  if (( types_size > TYPES_MAX )); then
    rm -f "$types_tmp"
    exit 0
  fi
  types=$(<"$types_tmp")
  rm -f "$types_tmp"
fi

if [[ ${CLIPBOARD_STATE:-} == "sensitive" ]] || grep -qx 'x-kde-passwordManagerHint' <<<"$types"; then
  exit 0
fi

emit_image() {
  local mime="$1"
  local ext tmp hash file

  ext=${mime#image/}
  [[ $ext == jpeg ]] && ext=jpg

  tmp=$(mktemp --tmpdir="$IMAGE_DIR" clipboard.XXXXXX) || return 0
  read_capped "$tmp" "$IMAGE_MAX" || return 0

  hash=$(sha256sum "$tmp" | awk '{print $1}')
  file="$IMAGE_DIR/$hash.$ext"
  if [[ -e $file ]]; then
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
  fi

  jq -cn --arg mime "$mime" --arg path "$file" --arg captured_at "$(date +'%A %H:%M')" \
    '{type:"image", mime:$mime, path:$path, capturedAt:$captured_at}'
}

emit_text() {
  local tmp json
  tmp=$(mktemp --tmpdir="$STATE_DIR" clipboard-text.XXXXXX) || return 0
  if ! read_capped "$tmp" "$TEXT_MAX"; then
    return 0
  fi

  json=$(
    perl -MEncode=decode,FB_CROAK,LEAVE_SRC -MJSON::PP=encode_json -e '
      binmode STDIN;
      my $raw = do { local $/; <STDIN> };
      exit unless defined $raw && length $raw;

      my $encoding;
      my $heuristic_encoding = 0;
      if ($raw =~ /^(?:\xFF\xFE|\xFE\xFF)/) {
        $encoding = "UTF-16";
      } elsif (length($raw) % 2 == 0 && index($raw, "\0") >= 0) {
        my $units = length($raw) / 2;
        my $nuls = $raw =~ tr/\0/\0/;

        # Neither byte lane can reach the padding threshold when the entire
        # payload contains fewer NULs than that, so avoid two full string passes.
        if ($nuls * 4 >= $units * 3) {
          my $even_bytes = $raw;
          $even_bytes =~ s/(.)./$1/sg;
          my $even_nuls = $even_bytes =~ tr/\0/\0/;
          undef $even_bytes;

          my $odd_bytes = $raw;
          $odd_bytes =~ s/.(.)/$1/sg;
          my $odd_nuls = $odd_bytes =~ tr/\0/\0/;

          # BOM-less UTF-16 is indistinguishable from NUL-separated bytes. Decode
          # only when at least three quarters of the code units have consistent
          # padding and fewer than one quarter have NULs in the opposite byte.
          if ($odd_nuls * 4 >= $units * 3 && $even_nuls * 4 < $units) {
            $encoding = "UTF-16LE";
            $heuristic_encoding = 1;
          } elsif ($even_nuls * 4 >= $units * 3 && $odd_nuls * 4 < $units) {
            $encoding = "UTF-16BE";
            $heuristic_encoding = 1;
          }
        }
      }

      my $text = $encoding ? eval { decode($encoding, $raw, FB_CROAK | LEAVE_SRC) } : undef;
      if ($heuristic_encoding && defined($text) && $text =~ /[\x00-\x08\x0E-\x1A\x1C-\x1F]/) {
        $text = undef;
      }
      $text = decode("UTF-8", $raw) unless defined $text;
      print "{\"type\":\"text\",\"text\":", encode_json($text), "}\n";
    ' <"$tmp"
  ) || true
  rm -f "$tmp"

  local json_bytes
  json_bytes=$(printf '%s' "$json" | wc -c)
  (( json_bytes > 0 && json_bytes <= JSON_MAX )) || return 0
  printf '%s' "$json"
  [[ $json == *$'\n' ]] || printf '\n'
}

case "${1:-}" in
text) emit_text; exit 0 ;;
image/*) emit_image "$1"; exit 0 ;;
esac

for mime in image/png image/jpeg image/webp image/gif image/bmp image/tiff; do
  if grep -qx "$mime" <<<"$types"; then
    timeout "$INGEST_TIMEOUT"s wl-paste --type "$mime" 2>/dev/null | emit_image "$mime"
    exit 0
  fi
done

if grep -q '^text/' <<<"$types" || grep -qx 'UTF8_STRING' <<<"$types" || grep -qx 'STRING' <<<"$types"; then
  timeout "$INGEST_TIMEOUT"s wl-paste --type text --no-newline 2>/dev/null | emit_text
fi
