#!/usr/bin/env bash
set -euo pipefail

APP="aojm"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/aojm"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/aojm"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/aojm"
SESSION_DIR_BASE="$DATA_DIR/sessions"
TRASH_DIR="$DATA_DIR/trash"
CONFIG_FILE="$CONF_DIR/config.env"
CURRENT_SESSION_FILE="$STATE_DIR/current_session"

mkdir -p "$CONF_DIR" "$STATE_DIR" "$DATA_DIR" "$SESSION_DIR_BASE" "$TRASH_DIR"

ensure_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" <<'EOF'
RECORDINGS_DIR="$HOME/aojm"
OUTPUT_WIDTH=1920
OUTPUT_HEIGHT=1080
CAMERA_WIDTH=320
CAMERA_MARGIN=20
FPS=15
CAMERA_FPS=30
ENCODER="auto"
AUDIO_ENABLED=1
AUDIO_DEVICE="default"
MAX_DURATION_SECONDS=18000
OPEN_BROWSER_DELAY_SECONDS=3
LOG_INTERVAL_SECONDS=30
KEEP_LAST=3
RCLONE_REMOTE=""
EOF
  fi
}

set_config_key() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ ("^" k "=") { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

get_meta() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, "", $0); print; exit }' "$file"
}

set_meta() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $0 ~ ("^" k "=") { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

log() { printf '[%s] %s\n' "$APP" "$*"; }
die() { printf '[%s] error: %s\n' "$APP" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || die "missing dependency: $1"; }

load_config() {
  ensure_config
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

screen_size() {
  if have xdpyinfo; then
    local s
    s="$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')"
    [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
  fi
  printf '1920x1080'
}

find_camera() {
  local d
  if have v4l2-ctl; then
    d="$(v4l2-ctl --list-devices 2>/dev/null | awk '
      /^[[:space:]]*$/ { next }
      /:$/ { next }
      /^[[:space:]]+\/dev\/video[0-9]+$/ { print $1; exit }
    ')"
    [[ -n "$d" && -e "$d" ]] && { printf '%s' "$d"; return 0; }
  fi
  for d in /dev/video*; do
    [[ -e "$d" ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

browser_hint() {
  if have xdg-settings; then
    xdg-settings get default-web-browser 2>/dev/null || true
  fi
}

latest_session_dir() {
  find "$SESSION_DIR_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{sub(/^[0-9.]+ /, ""); print}' | tail -n 1
}

all_sessions_sorted() {
  find "$SESSION_DIR_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{sub(/^[0-9.]+ /, ""); print}'
}

active_session_dir() {
  [[ -f "$CURRENT_SESSION_FILE" ]] || return 1
  cat "$CURRENT_SESSION_FILE"
}

pid_alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

check_init_deps() {
  need ffmpeg
  need xdg-open
  need xdg-settings
  need timeout

  if ! have rclone; then
    log "rclone is not installed; uploads disabled."
  fi
  
  if ! have xdotool && ! have xprop; then
    log "window-title logging skipped: missing xdotool/xprop."
  fi

  # Wayland Safety Check
  if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    printf '\n=======================================================\n'
    log "WARNING: Wayland Session Detected!"
    log "Due to Wayland security, screen capture requires a popup."
    log "Please approve the screen sharing dialog when it appears."
    log "Webcam and screen recordings will be saved as separate files."
    printf '=======================================================\n\n'
  fi
}

probe_encoder() {
  if [[ "$ENCODER" == "auto" ]]; then
    # Test if Nvidia hardware encoding works on the system
    if ffmpeg -v error -f lavfi -i color=c=black:s=16x16 -c:v h264_nvenc -frames:v 1 -f null - >/dev/null 2>&1; then
      printf "h264_nvenc"
    else
      printf "libx264"
    fi
  else
    printf "%s" "$ENCODER"
  fi
}

cmd_init() {
  load_config
  check_init_deps

  mkdir -p "$RECORDINGS_DIR"

  if find_camera >/dev/null 2>&1; then
    log "Webcam detected: $(find_camera)"
  else
    log "No webcam detected."
  fi

  local active_encoder
  active_encoder=$(probe_encoder)
  log "Selected Video Encoder: $active_encoder"

  if [[ "$AUDIO_ENABLED" == "1" ]]; then
    log "Audio recording is ENABLED. Device: $AUDIO_DEVICE"
  else
    log "Audio recording is DISABLED."
  fi

  if have rclone; then
    local remotes
    remotes="$(rclone listremotes 2>/dev/null || true)"
    remotes="$(trim "$remotes")"
    if [[ -n "$remotes" && -z "${RCLONE_REMOTE:-}" ]]; then
      RCLONE_REMOTE="$(printf '%s\n' "$remotes" | head -n1 | tr -d ':')"
      set_config_key "$CONFIG_FILE" RCLONE_REMOTE "\"$RCLONE_REMOTE\""
      log "Selected rclone remote: $RCLONE_REMOTE"
    elif [[ -z "$remotes" ]]; then
      log "No rclone remote configured."
      log "To enable cloud uploads to Google Drive, please run 'rclone config' in your terminal."
      log "Create a new remote named 'gdrive' of type Google Drive, follow the browser login steps, and then re-run '$APP init'."
    fi
  fi

  log "Init complete. Recordings directory: $RECORDINGS_DIR"
}

start_logger() {
  local log_file="$1" interval="$2" pid_file="$3"
  if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    log "Window title logging is natively blocked on Wayland."
    log "Suggestion: Install a GNOME Shell Extension (like 'Window Calls') if you need window titles. Skipping for now."
    return 0
  fi

  if ! have xdotool && ! have xprop; then
    return 0
  fi

  nohup bash -s -- "$log_file" "$interval" >/dev/null 2>&1 <<'EOF' &
set -euo pipefail
log_file="$1"
interval="$2"
last=""
while true; do
  title="unknown"
  if command -v xdotool >/dev/null 2>&1; then
    title="$(xdotool getactivewindow getwindowname 2>/dev/null | head -n1 | tr '\t' ' ')"
  elif command -v xprop >/dev/null 2>&1; then
    wid="$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | awk '{print $5}')"
    if [[ -n "${wid:-}" && "$wid" != "0x0" ]]; then
      title="$(xprop -id "$wid" WM_NAME 2>/dev/null | sed -n 's/^WM_NAME.*= //p' | head -n1)"
    fi
  fi
  title="${title:-unknown}"
  ts="$(date -Is)"
  if [[ "$title" != "$last" ]]; then
    printf '%s\tWINDOW\t%s\n' "$ts" "$title" >> "$log_file"
    last="$title"
  else
    printf '%s\tPING\t%s\n' "$ts" "$title" >> "$log_file"
  fi
  sleep "$interval"
done
EOF
  echo $! > "$pid_file"
}

start_recorder() {
  local recording_file="$1" ffmpeg_log="$2" backend_file="$3" session_dir="$4"
  local cam screen display active_encoder

  cam="$(find_camera || true)"
  screen="$(screen_size)"
  display="${DISPLAY:-:0.0}"
  active_encoder=$(probe_encoder)

  if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    local screen_file="$session_dir/screen.mkv"
    local cam_file="$session_dir/cam.mkv"

    printf '\n=======================================================\n'
    log "ACTION REQUIRED: A screen sharing dialog will now appear."
    log "Please select 'Share entire screen' or 'Entire Screen' to proceed."
    printf '=======================================================\n\n'

    # GStreamer command for Wayland Screen via Portal
    local gst_cmd=(
      gst-launch-1.0 -e pipewiresrc ! videoconvert ! x264enc tune=zerolatency ! matroskamux ! filesink location="$screen_file"
    )

    nohup timeout --signal=INT --kill-after=20s "$MAX_DURATION_SECONDS" "${gst_cmd[@]}" >> "$ffmpeg_log" 2>&1 &
    local gst_pid=$!

    # FFmpeg command for Webcam + Audio
    local ffmpeg_cmd=(
      ffmpeg -hide_banner -loglevel warning -y
    )

    if [[ -n "$cam" ]]; then
      ffmpeg_cmd+=(-thread_queue_size 512 -f v4l2 -framerate "$CAMERA_FPS" -i "$cam")
    else
      # Dummy video input if no webcam
      ffmpeg_cmd+=(-f lavfi -i color=c=black:s=${CAMERA_WIDTH}x240:r=$CAMERA_FPS)
    fi

    if [[ "$AUDIO_ENABLED" == "1" ]]; then
      ffmpeg_cmd+=(-thread_queue_size 512 -f pulse -i "$AUDIO_DEVICE")
    fi

    if [[ "$AUDIO_ENABLED" == "1" ]]; then
      ffmpeg_cmd+=(-c:a aac -b:a 128k)
    fi

    if [[ "$active_encoder" == "h264_nvenc" ]]; then
      ffmpeg_cmd+=(-c:v h264_nvenc -preset p4 -cq 28)
    else
      ffmpeg_cmd+=(-c:v libx264 -preset veryfast -crf 28)
    fi

    ffmpeg_cmd+=("$cam_file")

    nohup timeout --signal=INT --kill-after=20s "$MAX_DURATION_SECONDS" "${ffmpeg_cmd[@]}" >> "$ffmpeg_log" 2>&1 &
    local ff_pid=$!

    echo "$gst_pid" > "$backend_file"
    echo "$ff_pid" > "$session_dir/backend_ff.pid"

    set_meta "$session_dir/meta.env" RECORDING_FILE "$screen_file"
    set_meta "$session_dir/meta.env" RECORDING_FILE_CAM "$cam_file"

    return 0
  fi

  [[ -n "$cam" ]] || die "no webcam found"

  local filter_graph="[0:v]scale=${OUTPUT_WIDTH}:${OUTPUT_HEIGHT}:force_original_aspect_ratio=decrease,pad=${OUTPUT_WIDTH}:${OUTPUT_HEIGHT}:(ow-iw)/2:(oh-ih)/2,format=yuv420p[screen];[1:v]scale=${CAMERA_WIDTH}:-1,format=yuv420p,pad=iw+4:ih+4:2:2:color=black@0.35[cam];[screen][cam]overlay=W-w-${CAMERA_MARGIN}:H-h-${CAMERA_MARGIN}:format=auto[v]"

  # Construct ffmpeg command dynamically
  local ffmpeg_cmd=(
    ffmpeg -hide_banner -loglevel warning
    -thread_queue_size 512 -f x11grab -framerate "$FPS" -video_size "$screen" -i "$display+0,0"
    -thread_queue_size 512 -f v4l2 -framerate "$CAMERA_FPS" -i "$cam"
  )

  # Audio logic
  if [[ "$AUDIO_ENABLED" == "1" ]]; then
    ffmpeg_cmd+=(-thread_queue_size 512 -f pulse -i "$AUDIO_DEVICE")
  fi

  ffmpeg_cmd+=(-filter_complex "$filter_graph" -map "[v]")

  if [[ "$AUDIO_ENABLED" == "1" ]]; then
    ffmpeg_cmd+=(-map 2:a -c:a aac -b:a 128k)
  fi

  # Encoder logic
  if [[ "$active_encoder" == "h264_nvenc" ]]; then
    ffmpeg_cmd+=(-c:v h264_nvenc -preset p4 -cq 28)
  else
    ffmpeg_cmd+=(-c:v libx264 -preset veryfast -crf 28)
  fi

  ffmpeg_cmd+=(-pix_fmt yuv420p "$recording_file")

  nohup timeout --signal=INT --kill-after=20s "$MAX_DURATION_SECONDS" "${ffmpeg_cmd[@]}" >> "$ffmpeg_log" 2>&1 &
  echo $! > "$backend_file"
}

cmd_start() {
  load_config
  local url="${1:-}"
  [[ -n "$url" ]] || die "usage: $APP start <contest_url>"
  mkdir -p "$RECORDINGS_DIR" "$SESSION_DIR_BASE" "$TRASH_DIR"

  if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
    need gst-launch-1.0
  fi

  if [[ -f "$CURRENT_SESSION_FILE" ]]; then
    local cur backend
    cur="$(active_session_dir || true)"
    if [[ -n "$cur" && -f "$cur/backend.pid" ]]; then
      backend="$(cat "$cur/backend.pid")"
      if pid_alive "$backend"; then
        die "A recording is already active."
      fi
    fi
    rm -f "$CURRENT_SESSION_FILE"
  fi

  local session_id session_dir recording_file ffmpeg_log activity_log meta_file browser_log
  local contest_name
  contest_name="$(echo "$url" | sed 's|https*://||' | sed -E 's/[^a-zA-Z0-9]+/-/g' | sed 's/^-//;s/-$//')"
  session_id="$(date +%Y%m%d_%H%M%S)_${contest_name}"
  session_dir="$SESSION_DIR_BASE/$session_id"
  mkdir -p "$session_dir"
  
  echo "Computer Name: ${HOSTNAME:-unknown}" > "$session_dir/info.txt"

  recording_file="$session_dir/recording.mkv"
  ffmpeg_log="$session_dir/ffmpeg.log"
  activity_log="$session_dir/activity.log"
  meta_file="$session_dir/meta.env"
  browser_log="$session_dir/browser.log"

  cat > "$meta_file" <<EOF
SESSION_ID=$session_id
URL=$url
STARTED_AT=$(date -Is)
HOSTNAME=${HOSTNAME:-unknown}
RECORDING_FILE=$recording_file
UPLOADED=0
EOF

  printf '%s\n' "$session_dir" > "$CURRENT_SESSION_FILE"

  log "Opening browser..."
  xdg-open "$url" >> "$browser_log" 2>&1 &
  sleep "$OPEN_BROWSER_DELAY_SECONDS"

  log "Starting recorder..."
  start_recorder "$recording_file" "$ffmpeg_log" "$session_dir/backend.pid" "$session_dir"

  log "Starting activity logger..."
  start_logger "$activity_log" "$LOG_INTERVAL_SECONDS" "$session_dir/logger.pid"

  log "Recording started!"
  log "Run '$APP preview' to check the stream, or '$APP stop' to finish."
}

stop_backend() {
  local session_dir="$1"
  for b_file in "$session_dir/backend.pid" "$session_dir/backend_ff.pid"; do
    if [[ -f "$b_file" ]]; then
      local pid
      pid="$(cat "$b_file")"
      if pid_alive "$pid"; then
        kill -INT "$pid" >/dev/null 2>&1 || true
      fi
    fi
  done
}

cmd_stop() {
  load_config
  local session_dir
  session_dir="$(active_session_dir || true)"
  [[ -n "$session_dir" && -d "$session_dir" ]] || die "No active session."

  read -r -p "Are you sure you want to stop the recording? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { log "Stop aborted."; return 0; }

  stop_backend "$session_dir"

  if [[ -f "$session_dir/logger.pid" ]]; then
    kill -INT "$(cat "$session_dir/logger.pid")" >/dev/null 2>&1 || true
  fi

  set_meta "$session_dir/meta.env" STOPPED_AT "$(date -Is)"
  rm -f "$CURRENT_SESSION_FILE"
  log "Recording stopped."
}

cmd_status() {
  load_config
  local session_dir active meta backend started_at stopped_at recording_file size uploaded elapsed short_start short_stop

  session_dir="$(active_session_dir || true)"
  if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
    session_dir="$(latest_session_dir || true)"
  fi
  [[ -n "$session_dir" && -d "$session_dir" ]] || { log "No sessions yet."; return 0; }

  meta="$session_dir/meta.env"
  backend="$session_dir/backend.pid"
  started_at="$(get_meta "$meta" STARTED_AT || true)"
  stopped_at="$(get_meta "$meta" STOPPED_AT || true)"
  recording_file="$(get_meta "$meta" RECORDING_FILE || true)"
  uploaded="$(get_meta "$meta" UPLOADED || true)"
  active="No"

  if [[ -f "$backend" ]] && pid_alive "$(cat "$backend")"; then
    active="Yes"
  fi

  elapsed="n/a"
  if [[ "$active" == "Yes" && -n "$started_at" ]]; then
    local start_epoch now_epoch delta h m s
    start_epoch="$(date -d "$started_at" +%s 2>/dev/null || true)"
    if [[ -n "$start_epoch" ]]; then
      now_epoch="$(date +%s)"
      delta=$((now_epoch - start_epoch))
      (( delta < 0 )) && delta=0
      h=$((delta / 3600))
      m=$(((delta % 3600) / 60))
      s=$((delta % 60))
      elapsed="$(printf '%02d:%02d:%02d' "$h" "$m" "$s")"
    fi
  fi

  local recording_file_cam
  recording_file_cam="$(get_meta "$meta" RECORDING_FILE_CAM || true)"
  size="n/a"
  if [[ -f "$recording_file" && -n "$recording_file_cam" && -f "$recording_file_cam" ]]; then
    size="$(du -ch "$recording_file" "$recording_file_cam" 2>/dev/null | awk 'END{print $1}')"
  elif [[ -f "$recording_file" ]]; then
    size="$(du -h "$recording_file" 2>/dev/null | awk '{print $1}')"
  fi
  
  # Format dates for cleaner table output
  short_start=$(date -d "$started_at" '+%H:%M:%S' 2>/dev/null || echo "n/a")

  printf "\n"
  printf "%-25s | %-6s | %-10s | %-10s | %-8s | %-4s\n" "SESSION" "ACTIVE" "START TIME" "ELAPSED" "SIZE" "UP?"
  printf "%-25s | %-6s | %-10s | %-10s | %-8s | %-4s\n" "-------------------------" "------" "----------" "----------" "--------" "----"
  printf "%-25s | %-6s | %-10s | %-10s | %-8s | %-4s\n" "$(basename "$session_dir")" "$active" "$short_start" "$elapsed" "$size" "${uploaded:-0}"
  printf "\n"
}

cmd_preview() {
  local session_dir file
  session_dir="$(active_session_dir || true)"
  if [[ -z "$session_dir" ]]; then
      session_dir="$(latest_session_dir || true)"
  fi
  [[ -n "$session_dir" ]] || die "No session to preview."

  file="$(get_meta "$session_dir/meta.env" RECORDING_FILE || true)"
  if [[ -z "$file" || ! -f "$file" ]]; then
    file="$session_dir/recording.mkv"
  fi
  [[ -f "$file" ]] || die "Recording file not found: $file"

  local cam_file
  cam_file="$(get_meta "$session_dir/meta.env" RECORDING_FILE_CAM || true)"
  if [[ -n "$cam_file" && -f "$cam_file" ]]; then
      log "Note: A separate webcam recording is also available at: $(basename "$cam_file")"
  fi

  log "Previewing video stream. Close the media player to return to the terminal."
  if have mpv; then
      mpv "$file" >/dev/null 2>&1 &
  elif have vlc; then
      vlc "$file" >/dev/null 2>&1 &
  else
      xdg-open "$file" >/dev/null 2>&1 &
  fi
}

cmd_settings() {
  ensure_config
  local action="${1:-list}"
  local key="${2:-}"
  local value="${3:-}"

  if [[ "$action" == "list" ]]; then
    printf "\n--- Current Settings (%s) ---\n" "$CONFIG_FILE"
    cat "$CONFIG_FILE"
    printf "------------------------------------------------------\n"
    log "To change a setting: $APP settings set <KEY> <VALUE>"
  elif [[ "$action" == "set" ]]; then
    [[ -n "$key" && -n "$value" ]] || die "Usage: $APP settings set <KEY> <VALUE>"
    set_config_key "$CONFIG_FILE" "$key" "$value"
    log "Updated $key = $value"
  else
    die "Unknown settings action: $action. Use 'list' or 'set'."
  fi
}

upload_one() {
  local session_dir="$1"
  [[ -d "$session_dir" ]] || return 0
  [[ -f "$session_dir/meta.env" ]] || return 0
  [[ -n "${RCLONE_REMOTE:-}" ]] || die "No rclone remote configured. Run 'rclone config' then '$APP init'."

  local name dest
  name="$(basename "$session_dir")"
  dest="${RCLONE_REMOTE%:}:aojm/$name"

  log "Uploading $name to $dest..."
  
  # Check free space if supported
  local size_bytes free_bytes
  size_bytes="$(du -sb "$session_dir" 2>/dev/null | awk '{print $1}')"
  free_bytes="$(rclone about "${RCLONE_REMOTE%:}:" --json 2>/dev/null | grep -Po '"free": ?\K[0-9]+' || echo "unknown")"
  
  if [[ -n "$size_bytes" && "$free_bytes" != "unknown" && -n "$free_bytes" ]]; then
    if (( size_bytes > free_bytes )); then
      log "WARNING: Not enough free space on remote! Required: $size_bytes, Free: $free_bytes"
      log "Skipping upload of $name."
      return 0
    fi
  fi

  # Replaced >/dev/null with visible progress (-P)
  rclone copy -P "$session_dir" "$dest"
  
  set_meta "$session_dir/meta.env" UPLOADED 1
  set_meta "$session_dir/meta.env" UPLOADED_AT "$(date -Is)"
  log "Successfully uploaded $name."
}

cmd_upload() {
  load_config
  local mode="${1:-recent}"
  local sessions=() dir count=0 start i current uploaded
  current="$(active_session_dir || true)"

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    [[ -n "$current" && "$dir" == "$current" ]] && continue
    if [[ -f "$dir/backend.pid" ]] && pid_alive "$(cat "$dir/backend.pid")"; then
      continue
    fi
    uploaded="$(get_meta "$dir/meta.env" UPLOADED || true)"
    [[ "$uploaded" == "1" ]] && continue
    sessions+=("$dir")
  done < <(all_sessions_sorted)

  [[ ${#sessions[@]} -gt 0 ]] || { log "No pending sessions to upload."; return 0; }

  if [[ "$mode" == "all" ]]; then
    for dir in "${sessions[@]}"; do
      upload_one "$dir"
      count=$((count + 1))
    done
  else
    start=0
    (( ${#sessions[@]} > KEEP_LAST )) && start=$(( ${#sessions[@]} - KEEP_LAST ))
    for ((i=start; i<${#sessions[@]}; i++)); do
      upload_one "${sessions[$i]}"
      count=$((count + 1))
    done
  fi

  log "Uploaded $count session(s)."
}

cmd_clean() {
  load_config
  local arg="${1:-}"
  
  # Handle empty trash directly
  if [[ "$arg" == "--empty-trash" ]]; then
      log "Emptying trash directory..."
      rm -rf "$TRASH_DIR"/*
      log "Trash cleared."
      return 0
  fi

  local keep="${1:-$KEEP_LAST}"
  local yes="${2:-no}"
  local sessions=() dir current uploaded i delete_from
  current="$(active_session_dir || true)"

  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    [[ -n "$current" && "$dir" == "$current" ]] && continue
    if [[ -f "$dir/backend.pid" ]] && pid_alive "$(cat "$dir/backend.pid")"; then
      continue
    fi
    uploaded="$(get_meta "$dir/meta.env" UPLOADED || true)"
    [[ "$uploaded" == "1" ]] || continue
    sessions+=("$dir")
  done < <(all_sessions_sorted)

  [[ ${#sessions[@]} -gt keep ]] || { log "Nothing to clean."; return 0; }

  delete_from=$(( ${#sessions[@]} - keep ))
  printf 'Will move %d session(s) to trash:\n' "$delete_from"
  for ((i=0; i<delete_from; i++)); do
    printf '  %s\n' "${sessions[$i]}"
  done

  if [[ "$yes" != "--yes" ]]; then
    read -r -p "Trash these sessions? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { log "Aborted."; return 0; }
  fi

  for ((i=0; i<delete_from; i++)); do
    mv "${sessions[$i]}" "$TRASH_DIR/" 2>/dev/null || rm -rf "${sessions[$i]}"
  done
  log "Clean complete. Use '$APP clean --empty-trash' to permanently delete."
}

cmd_update() {
  log "Checking for updates..."
  local tmp_file
  tmp_file="$(mktemp)"
  
  if ! curl -s --connect-timeout 5 "https://raw.githubusercontent.com/vibhaas/aojm/main/aojm.sh" -o "$tmp_file"; then
    log "Network offline or repository unreachable. Skipping update."
    rm -f "$tmp_file"
    return 0
  fi
  
  if cmp -s "$0" "$tmp_file"; then
    log "Already up to date."
    rm -f "$tmp_file"
    return 0
  fi
  
  log "Update found! Applying..."
  if ! cp "$tmp_file" "$0" 2>/dev/null; then
    log "Permission denied. Attempting to run update with sudo..."
    if sudo cp "$tmp_file" "$0"; then
      sudo chmod +x "$0"
      log "Successfully updated!"
      rm -f "$tmp_file"
      exit 0
    else
      log "Failed to update due to permissions. Please run: sudo $APP update"
    fi
  else
    chmod +x "$0"
    log "Successfully updated!"
    rm -f "$tmp_file"
    exit 0
  fi
  
  rm -f "$tmp_file"
}

usage() {
  cat <<EOF
Usage: $APP <command> [options]

Commands:
  init       Initialize configuration, detect hardware, and setup cloud storage.
  start      <contest_url> Open the URL and start recording (screen, webcam, audio).
  stop       Stop the current active recording session.
  status     View the status and size of active and recent sessions.
  preview    Preview the current or latest video recording stream.
  upload     [recent|all] Safely upload completed recordings to Google Drive/cloud.
  clean      [keep_count] [--yes] | --empty-trash Move old sessions to trash or permanently empty.
  settings   [list | set <key> <value>] View or modify configuration settings.
  update     Check GitHub for updates and automatically patch the local installation.
  help       Show this help message.
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    init) cmd_init "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    preview) cmd_preview "$@" ;;
    upload) cmd_upload "${1:-recent}" ;;
    clean) cmd_clean "${1:-$KEEP_LAST}" "${2:-no}" ;;
    settings) cmd_settings "$@" ;;
    update) cmd_update ;;
    ""|-h|--help|help) usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"