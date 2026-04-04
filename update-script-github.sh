#!/bin/sh

set -eu

BASE_DIR="/usr/local/mnt/sda1"
RUT_URL="https://raw.githubusercontent.com/sigit-netra/agent-test/main/rut-datalogger"
UI_URL="https://raw.githubusercontent.com/sigit-netra/agent-test/main/ui-rut-datalogger"
CONFIG_URL="https://raw.githubusercontent.com/sigit-netra/agent-test/main/config-rut.yaml"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TMP_DIR="/tmp/rut-update.$$"

mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

backup_path() {
  src="$1"
  dst="$2"

  if [ ! -e "$src" ]; then
    echo "Lewati backup, path tidak ditemukan: $src"
    return 0
  fi

  if [ -e "$dst" ]; then
    rotated_dst="${dst}-${TIMESTAMP}"
    echo "Backup lama sudah ada, pindahkan: $dst -> $rotated_dst"
    mv "$dst" "$rotated_dst"
  fi

  echo "Backup path: $src -> $dst"
  mv "$src" "$dst"
}

merge_config() {
  current_file="$1"
  remote_file="$2"
  merged_file="$3"
  work_dir="$4"

  current_norm="$work_dir/current.norm.yaml"
  remote_norm="$work_dir/remote.norm.yaml"

  tr -d '\r' < "$current_file" > "$current_norm"
  tr -d '\r' < "$remote_file" > "$remote_norm"

  awk '
    BEGIN {
      preserve["water_table"] = 1
      preserve["device_identity"] = 1
      preserve["modbus_sensors"] = 1
    }

    function is_top_level_key(line) {
      return line ~ /^[A-Za-z0-9_-]+:/
    }

    function key_name(line,    parts) {
      split(line, parts, ":")
      return parts[1]
    }

    function is_comment_or_blank(line) {
      return line ~ /^[[:space:]]*$/ || line ~ /^#/
    }

    function append_line(target, mode, key, text) {
      if (target == "header") {
        header[mode] = header[mode] text
      } else if (target == "leading") {
        leading[mode, key] = leading[mode, key] text
      } else {
        body[mode, key] = body[mode, key] text
      }
    }

    function flush_pending(mode, current_key, target,    i) {
      for (i = 1; i <= pending_count; i++) {
        append_line(target, mode, current_key, pending[i])
      }
      pending_count = 0
    }

    function finish_file(mode) {
      if (mode == "") {
        return
      }
      if (current_key != "") {
        flush_pending(mode, current_key, "leading")
      } else {
        flush_pending(mode, "", "header")
      }
    }

    FNR == 1 {
      finish_file(mode)
      mode = (ARGIND == 1 ? "current" : "remote")
      current_key = ""
      pending_count = 0
      key_count[mode] = 0
    }

    {
      line = $0 ORS

      if (is_top_level_key($0)) {
        current_key = key_name($0)
        order[mode, ++key_count[mode]] = current_key
        flush_pending(mode, current_key, "leading")
        append_line("body", mode, current_key, line)
        next
      }

      if (is_comment_or_blank($0)) {
        pending[++pending_count] = line
        next
      }

      if (current_key == "") {
        flush_pending(mode, "", "header")
        append_line("header", mode, "", line)
      } else {
        flush_pending(mode, current_key, "body")
        append_line("body", mode, current_key, line)
      }
    }

    END {
      finish_file(mode)

      printf "%s", header["remote"]

      for (i = 1; i <= key_count["remote"]; i++) {
        key = order["remote", i]

        if (preserve[key] && body["current", key] != "") {
          printf "%s", leading["remote", key]
          if (leading["current", key] != "" && leading["current", key] != leading["remote", key]) {
            printf "%s", leading["current", key]
          }
          printf "%s", body["current", key]
          emitted[key] = 1
        } else {
          printf "%s", leading["remote", key]
          printf "%s", body["remote", key]
        }
      }

      for (key in preserve) {
        if (!emitted[key] && body["current", key] != "") {
          printf "%s", leading["current", key]
          printf "%s", body["current", key]
        }
      }
    }
  ' "$current_norm" "$remote_norm" > "$merged_file"
}

echo "Step 1: pindah ke $BASE_DIR"
cd "$BASE_DIR"

echo "Step 2: download binary baru"
uclient-fetch -O rut-datalogger-new "$RUT_URL"
uclient-fetch -O ui-rut-datalogger-new "$UI_URL"
chmod +x rut-datalogger-new ui-rut-datalogger-new
ls -lh rut-datalogger-new ui-rut-datalogger-new

echo "Step 3: rename folder netra_db -> netra_db-old"
backup_path "$BASE_DIR/netra_db" "$BASE_DIR/netra_db-old"

echo "Step 4: rename rut-datalogger -> rut-datalogger-old"
backup_path "$BASE_DIR/rut-datalogger" "$BASE_DIR/rut-datalogger-old"

echo "Step 5: rename ui-rut-datalogger -> ui-rut-datalogger-old"
backup_path "$BASE_DIR/ui-rut-datalogger" "$BASE_DIR/ui-rut-datalogger-old"

echo "Aktifkan binary baru"
mv "$BASE_DIR/rut-datalogger-new" "$BASE_DIR/rut-datalogger"
mv "$BASE_DIR/ui-rut-datalogger-new" "$BASE_DIR/ui-rut-datalogger"
chmod +x "$BASE_DIR/rut-datalogger" "$BASE_DIR/ui-rut-datalogger"

echo "Siapkan ulang folder database"
mkdir -p "$BASE_DIR/netra_db"

echo "Step 6: skip update config-rut.yaml"
# echo "Step 6: update config-rut.yaml dari template GitHub"
# REMOTE_CONFIG="$TMP_DIR/config-rut.remote.yaml"
# MERGED_CONFIG="$TMP_DIR/config-rut.merged.yaml"
# CURRENT_CONFIG="$BASE_DIR/config-rut.yaml"

# uclient-fetch -O "$REMOTE_CONFIG" "$CONFIG_URL"

# if [ -f "$CURRENT_CONFIG" ]; then
#   cp "$CURRENT_CONFIG" "$BASE_DIR/config-rut.yaml.bak.$TIMESTAMP"
#   merge_config "$CURRENT_CONFIG" "$REMOTE_CONFIG" "$MERGED_CONFIG" "$TMP_DIR"
#   cp "$MERGED_CONFIG" "$CURRENT_CONFIG"
# else
#   cp "$REMOTE_CONFIG" "$CURRENT_CONFIG"
# fi

echo "Step 7: restart service"
/etc/init.d/rut-datalogger restart
/etc/init.d/ui-rut-datalogger restart

echo "Update selesai"
