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

find_section_start_line() {
  key="$1"
  input_file="$2"

  awk -v key="$key" '
    {
      lines[NR] = $0
    }
    END {
      key_line = 0
      for (i = 1; i <= NR; i++) {
        if (lines[i] ~ "^" key ":") {
          key_line = i
          break
        }
      }

      if (key_line == 0) {
        exit 1
      }

      start_line = key_line
      while (start_line > 1) {
        prev_line = lines[start_line - 1]
        if (prev_line ~ /^#/ || prev_line ~ /^$/) {
          start_line--
        } else {
          break
        }
      }

      print start_line
    }
  ' "$input_file"
}

find_key_line() {
  key="$1"
  input_file="$2"

  awk -v key="$key" '
    $0 ~ "^" key ":" {
      print NR
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$input_file"
}

find_section_body_end_line() {
  key="$1"
  input_file="$2"

  awk -v key="$key" '
    {
      lines[NR] = $0
    }
    END {
      key_line = 0
      for (i = 1; i <= NR; i++) {
        if (lines[i] ~ "^" key ":") {
          key_line = i
          break
        }
      }

      if (key_line == 0) {
        exit 1
      }

      end_line = NR
      for (i = key_line + 1; i <= NR; i++) {
        if (lines[i] ~ "^[A-Za-z0-9_-]+:") {
          end_line = i - 1
          break
        }
      }

      while (end_line > key_line && (lines[end_line] ~ /^#/ || lines[end_line] ~ /^$/)) {
        end_line--
      }

      print end_line
    }
  ' "$input_file"
}

validate_preserved_tail() {
  input_file="$1"

  awk '
    /^[A-Za-z0-9_-]+:/ {
      key = $1
      sub(/:$/, "", key)
      keys[++count] = key
    }
    END {
      if (count < 3) {
        exit 1
      }
      if (keys[count - 2] != "water_table") {
        exit 1
      }
      if (keys[count - 1] != "device_identity") {
        exit 1
      }
      if (keys[count] != "modbus_sensors") {
        exit 1
      }
    }
  ' "$input_file"
}

append_preserved_section() {
  key="$1"
  local_file="$2"
  remote_file="$3"
  output_file="$4"
  work_dir="$5"

  local_start="$(find_section_start_line "$key" "$local_file")" || return 1
  local_key_line="$(find_key_line "$key" "$local_file")" || return 1
  local_end="$(find_section_body_end_line "$key" "$local_file")" || return 1
  remote_start="$(find_section_start_line "$key" "$remote_file")" || return 1
  remote_key_line="$(find_key_line "$key" "$remote_file")" || return 1

  remote_leading="$work_dir/${key}.remote.leading"
  local_leading="$work_dir/${key}.local.leading"

  : > "$remote_leading"
  : > "$local_leading"

  if [ "$remote_start" -lt "$remote_key_line" ]; then
    sed -n "${remote_start},$((remote_key_line - 1))p" "$remote_file" > "$remote_leading"
    cat "$remote_leading" >> "$output_file"
  fi

  if [ "$local_start" -lt "$local_key_line" ]; then
    sed -n "${local_start},$((local_key_line - 1))p" "$local_file" > "$local_leading"
    if ! cmp -s "$remote_leading" "$local_leading"; then
      cat "$local_leading" >> "$output_file"
    fi
  fi

  sed -n "${local_key_line},${local_end}p" "$local_file" >> "$output_file"
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

  validate_preserved_tail "$current_norm" || {
    echo "Urutan tail config lokal berubah. Expected tail: water_table -> device_identity -> modbus_sensors"
    return 1
  }
  validate_preserved_tail "$remote_norm" || {
    echo "Urutan tail config remote berubah. Expected tail: water_table -> device_identity -> modbus_sensors"
    return 1
  }

  remote_head_stop="$(find_section_start_line "water_table" "$remote_norm")" || {
    echo "Gagal menemukan section water_table di $remote_file"
    return 1
  }
  remote_head_end=$((remote_head_stop - 1))

  if [ "$remote_head_end" -gt 0 ]; then
    sed -n "1,${remote_head_end}p" "$remote_norm" > "$merged_file"
  else
    : > "$merged_file"
  fi

  append_preserved_section "water_table" "$current_norm" "$remote_norm" "$merged_file" "$work_dir" || {
    echo "Gagal merge section water_table"
    return 1
  }
  append_preserved_section "device_identity" "$current_norm" "$remote_norm" "$merged_file" "$work_dir" || {
    echo "Gagal merge section device_identity"
    return 1
  }
  append_preserved_section "modbus_sensors" "$current_norm" "$remote_norm" "$merged_file" "$work_dir" || {
    echo "Gagal merge section modbus_sensors"
    return 1
  }
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

echo "Step 6: update config-rut.yaml dari template GitHub"
REMOTE_CONFIG="$TMP_DIR/config-rut.remote.yaml"
MERGED_CONFIG="$TMP_DIR/config-rut.merged.yaml"
CURRENT_CONFIG="$BASE_DIR/config-rut.yaml"

uclient-fetch -O "$REMOTE_CONFIG" "$CONFIG_URL"

if [ -f "$CURRENT_CONFIG" ]; then
  cp "$CURRENT_CONFIG" "$BASE_DIR/config-rut.yaml.bak.$TIMESTAMP"
  merge_config "$CURRENT_CONFIG" "$REMOTE_CONFIG" "$MERGED_CONFIG" "$TMP_DIR"
  cp "$MERGED_CONFIG" "$CURRENT_CONFIG"
else
  cp "$REMOTE_CONFIG" "$CURRENT_CONFIG"
fi

echo "Step 7: restart service"
/etc/init.d/rut-datalogger restart
/etc/init.d/ui-rut-datalogger restart

echo "Update selesai"
