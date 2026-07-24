#!/usr/bin/env bash
set -euo pipefail

DIFF_FILE=${1:?diff file is required}
WORK_DIR=${2:?work directory is required}
BATCH_MAX_BYTES=${BATCH_MAX_BYTES:-50000}
FILE_MAX_BYTES=${FILE_MAX_BYTES:-120000}
MAX_BATCHES=${MAX_BATCHES:-8}

for value_name in BATCH_MAX_BYTES FILE_MAX_BYTES MAX_BATCHES; do
  value=${!value_name}
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$value_name must be a positive integer" >&2
    exit 1
  fi
done

if [ ! -f "$DIFF_FILE" ]; then
  echo "diff file does not exist: $DIFF_FILE" >&2
  exit 1
fi

FILES_DIR="$WORK_DIR/files"
BATCHES_DIR="$WORK_DIR/batches"
OVERFLOW_NOTE="$WORK_DIR/overflow.note"

rm -rf -- "$FILES_DIR" "$BATCHES_DIR"
mkdir -p "$FILES_DIR" "$BATCHES_DIR"
: > "$OVERFLOW_NOTE"

if grep -q '^diff --git ' "$DIFF_FILE"; then
  awk -v output_dir="$FILES_DIR" '
    /^diff --git / {
      n++
      out = sprintf("%s/%03d", output_dir, n - 1)
    }
    { if (out != "") print > out }
  ' "$DIFF_FILE"
else
  cp "$DIFF_FILE" "$FILES_DIR/000"
fi

batch_index=0
current_batch="$BATCHES_DIR/batch_$(printf '%03d' "$batch_index").diff"
: > "$current_batch"
current_bytes=0

for fragment in "$FILES_DIR"/*; do
  [ -f "$fragment" ] || continue

  first_line=$(head -n 1 "$fragment")
  file_path=$(printf '%s\n' "$first_line" | sed -E 's/^diff --git a\/(.*) b\/.*$/\1/')
  file_bytes=$(wc -c < "$fragment")

  if [ "$file_bytes" -gt "$FILE_MAX_BYTES" ]; then
    head -c "$FILE_MAX_BYTES" "$fragment" > "$fragment.tmp"
    printf '\n[... file %s truncated at %s bytes for review ...]\n' \
      "$file_path" "$FILE_MAX_BYTES" >> "$fragment.tmp"
    mv "$fragment.tmp" "$fragment"
    file_bytes=$(wc -c < "$fragment")
    printf '%s\n' \
      "- file \`$file_path\` exceeded $FILE_MAX_BYTES bytes and was truncated for review" \
      >> "$OVERFLOW_NOTE"
  fi

  if [ "$current_bytes" -gt 0 ] \
    && [ $((current_bytes + file_bytes)) -gt "$BATCH_MAX_BYTES" ]; then
    batch_index=$((batch_index + 1))
    if [ "$batch_index" -ge "$MAX_BATCHES" ]; then
      printf '%s\n' \
        "- batch cap ($MAX_BATCHES) reached: remaining files were NOT reviewed" \
        >> "$OVERFLOW_NOTE"
      break
    fi
    current_batch="$BATCHES_DIR/batch_$(printf '%03d' "$batch_index").diff"
    : > "$current_batch"
    current_bytes=0
  fi

  cat "$fragment" >> "$current_batch"
  current_bytes=$(wc -c < "$current_batch")
done

batch_count=0
for batch in "$BATCHES_DIR"/batch_*.diff; do
  if [ -s "$batch" ]; then
    batch_count=$((batch_count + 1))
  fi
done

echo "$batch_count" > "$WORK_DIR/batch.count"
echo "batches: $batch_count"

if [ -s "$OVERFLOW_NOTE" ]; then
  echo "::notice::AI review has partial coverage; details will be included in the PR comment."
fi
