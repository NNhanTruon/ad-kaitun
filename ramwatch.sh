#!/bin/bash
# AD RAM Watchdog — chỉ force-stop com.roblox.client. KHÔNG bao giờ đụng process khác
# (openchamber, tailscale, termux, adb... đều an toàn).
LOG=/tmp/opencode/ramwatch.log
DEV="127.0.0.1:5555"
LOW_KB=$((700*1024))     # MemAvailable < 700MB  -> kill roblox
SAFE_KB=$((1500*1024))   # MemAvailable > 1.5GB  -> relaunch roblox
PKG="com.roblox.client"
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
log "ramwatch v3 started (low=${LOW_KB}KB safe=${SAFE_KB}KB)"
while true; do
  state=$(timeout 10 adb -s $DEV get-state 2>/dev/null)
  if [ "$state" != "device" ]; then
    timeout 10 adb connect $DEV >/dev/null 2>&1
    state=$(timeout 10 adb -s $DEV get-state 2>/dev/null)
    if [ "$state" != "device" ]; then
      sleep 15
      continue
    fi
  fi
  avail=$(timeout 10 adb -s $DEV shell cat /proc/meminfo 2>/dev/null | awk '/MemAvailable/{print $2}')
  running=$(timeout 10 adb -s $DEV shell pidof $PKG 2>/dev/null)
  if [ -z "$avail" ]; then
    sleep 15
    continue
  fi
  if [ "$avail" -lt "$LOW_KB" ] && [ -n "$running" ]; then
    log "LOW RAM ${avail}KB (pid $running) -> force-stop $PKG"
    timeout 25 adb -s $DEV shell am force-stop $PKG >> "$LOG" 2>&1
    sleep 90
  elif [ -z "$running" ] && [ "$avail" -gt "$SAFE_KB" ]; then
    log "roblox DEAD + RAM ok ${avail}KB -> relaunch $PKG"
    timeout 25 adb -s $DEV shell am start -a android.intent.action.VIEW -d 'roblox://placeId=6938803436' $PKG >> "$LOG" 2>&1
    sleep 120
  else
    sleep 20
  fi
done