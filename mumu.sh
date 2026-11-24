#!/usr/bin/env bash
# mumu.sh —— MuMu Pro 模拟器操作封装（本次实战沉淀）
#
# 用法：
#   ./mumu.sh serial                 打印当前设备 ADB serial（自动探测端口）
#   ./mumu.sh reset                  重置设备（备份旧盘 → 换新盘 → 等开机）
#   ./mumu.sh proxy up               起本地轮换转发器（自动换节点），免认证入口指向 IPRoyal
#   ./mumu.sh proxy ip               看当前出口 IP
#   ./mumu.sh proxy down             停转发器
#   ./mumu.sh net on|off             设备代理开/关（指向本机转发器）
#   ./mumu.sh play                   按正确顺序拉起 Play 商店（先杀 frida）
#   ./mumu.sh frida on|off           frida-server 起/停（务必在 Play 之后）
#   ./mumu.sh check                  跑 pro0.py --check（会清设备代理，随后自动恢复）
#   ./mumu.sh run-18m                拉 18 个月免费 Pro
#   ./mumu.sh shot                   截图到 /tmp/mumu-$(date).png 并打印路径
#
# 已知硬约束（踩过的坑，别改）：
#   1. ADB 端口每次重启都变，必须动态探测，不能写死 5555/26624。
#   2. frida-server 必须先于 Play 商店存在时 Play 会 attach 超时被杀（50s）→
#      正确顺序永远是：先 play，后 frida。
#   3. Android 全局 http_proxy 不支持账密 → 必须走本机 rotating_proxy.py 免认证转发。
#   4. pro0.py --check 会执行 settings put global http_proxy :0 清代理，跑完要恢复。

set -uo pipefail

CLI="/Applications/MuMuPlayer Pro.app/Contents/MacOS/mumu-cli"
WORK="/Users/jiajingqiu/Downloads/one-sku-study"
PY="/Users/jiajingqiu/.local/bin/python3.12"
PROXY_FILE="/Users/jiajingqiu/Desktop/iproyal-proxies.txt"
FORWARD_PORT=18790
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="/tmp/mumu-run.log"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }
die() { log "❌ $*"; exit 1; }

# ---- 设备 ----
find_serial() {
  # 优先用 mumu-cli 报的 adb_port，其次扫已连接设备
  local port
  port=$("$CLI" info all 2>/dev/null | sed -n 's/.*"adb_port" : \([0-9]*\).*/\1/p' | head -1)
  [ -n "$port" ] && adb connect "127.0.0.1:$port" >/dev/null 2>&1
  local s
  s=$(adb devices | awk '$2=="device"{print $1; exit}')
  [ -n "$s" ] || die "没有可用设备，先 ./mumu.sh boot"
  echo "$s"
}

boot() {
  # 找一台 stopped 设备启动
  local st
  st=$("$CLI" info all 2>/dev/null | grep -o '"state" : "[a-z]*"' | head -1 | cut -d'"' -f4)
  if [ "$st" = "stopped" ]; then
    "$CLI" open 0 >/dev/null || die "启动失败"
    log "已下发开机，等待 ADB…"
  fi
  local i
  for i in $(seq 1 90); do
    find_serial >/dev/null 2>&1 && { log "设备就绪"; return 0; }
    sleep 3
  done
  die "等不到 ADB"
}

wait_boot() {
  local s i
  s=$(find_serial)
  for i in $(seq 1 60); do
    [ "$(adb -s "$s" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && { log "系统已启动完成"; return 0; }
    sleep 3
  done
  die "系统没起来"
}

# ---- 重置 ----
do_reset() {
  local s v backup
  s=$(find_serial 2>/dev/null || true)
  log "关闭模拟器…"
  "$CLI" close 0 >/dev/null 2>&1 || true
  sleep 4
  v="/Users/jiajingqiu/Library/Application Support/com.netease.mumu.nemux-global/vms/0"
  backup="$v/backup_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$backup"
  mv "$v/data.qcow2" "$v/data.qcow2.json" "$backup/" 2>/dev/null || die "移动数据盘失败（还有进程占用？）"
  log "旧盘已备份到 $backup"
  "$CLI" open 0 >/dev/null || die "重新开机失败"
  sleep 5
  wait_boot
  "$CLI" config 0 --setting '{"vmRootEnable":true}' >/dev/null 2>&1
  adb -s "$(find_serial)" root >/dev/null 2>&1 || true
  log "✅ 重置完成（干净系统）"
}

# ---- 代理 ----
proxy_up() {
  local s ok=0 i
  # IPRoyal 节点会随机回 403（实测单节点约一半失败，且是突发性的）。
  # 对策：rotating_proxy.py 本地免认证转发，每次连接自动在多个上游里换节点。
  [ -f "$PROXY_FILE" ] || die "没有代理列表 $PROXY_FILE"
  proxy_down 2>/dev/null || true
  nohup "$PY" "$DIR/rotating_proxy.py" --list "$PROXY_FILE" --port "$FORWARD_PORT" \
    >/tmp/rotating-proxy.log 2>&1 &
  sleep 2
  pgrep -f "rotating_proxy.py.*$FORWARD_PORT" >/dev/null || die "转发器没起来，看 /tmp/rotating-proxy.log"
  for i in $(seq 1 10); do
    curl -s -m 15 -x "http://127.0.0.1:$FORWARD_PORT" -o /dev/null -w "%{http_code}" \
      https://api.ipify.org 2>/dev/null | grep -q 200 && ok=$((ok+1))
    sleep 1
  done
  [ "$ok" -ge 7 ] || die "转发器质量不足（10 次试连成功 $ok 次），看 /tmp/rotating-proxy.log"
  log "✅ 转发器已起（本地 $FORWARD_PORT，试连 $ok/10）"
}

proxy_ip() {
  local ip
  ip=$(curl -s -m 12 -x "http://127.0.0.1:$FORWARD_PORT" https://api.ipify.org)
  log "出口 IP：${ip:-<失败>}"
  [ -n "$ip" ] || return 1
}

proxy_down() { pkill -f "rotating_proxy.py.*$FORWARD_PORT" && log "转发器已停"; }

net_on() {
  local s; s=$(find_serial)
  adb -s "$s" shell "settings put global http_proxy 10.0.2.2:$FORWARD_PORT" >/dev/null
  log "✅ 设备代理 → 10.0.2.2:$FORWARD_PORT"
  adb -s "$s" shell "curl -s -m 10 https://api.ipify.org" 2>/dev/null | sed 's/^/   设备出口：/'
}

net_off() { local s; s=$(find_serial); adb -s "$s" shell "settings put global http_proxy :0" >/dev/null; log "设备代理已关"; }

# ---- Play / frida（顺序敏感）----
# Play 必须在 frida-server 缺席时启动，否则 fork 后 attach 超时被杀（50s start timeout）。
# 而且判定「起来了」不能只看进程在——广播会临时拉起进程又退出。
# 标准：fork 出的主进程能活过 20 秒（跨过一次 AM 的超时窗口），才算真起来。
PLAY_SETTLE=20

play_alive() { local s=$1; adb -s "$s" shell "pidof com.android.vending" 2>/dev/null | tr -d '\r'; }

play_up() {
  local s; s=$(find_serial)
  adb -s "$s" shell "pkill -f frida-server" 2>/dev/null || true
  sleep 1
  adb -s "$s" shell "am force-stop com.android.vending" 2>/dev/null || true
  local i pid
  for i in $(seq 1 20); do
    adb -s "$s" shell am start -n com.android.vending/com.google.android.finsky.activities.MainActivity >/dev/null 2>&1
    sleep 8
    pid=$(play_alive "$s")
    [ -n "$pid" ] || continue
    sleep "$PLAY_SETTLE"
    if [ "$(play_alive "$s")" = "$pid" ]; then
      log "✅ Play 已稳定运行（pid $pid，活过 ${PLAY_SETTLE}s）"
      return 0
    fi
    log "Play 起后又死了，重试（$i）"
    adb -s "$s" shell "am force-stop com.android.vending" 2>/dev/null || true
    sleep 2
  done
  die "Play 商店反复起不来，看 logcat：adb logcat -d | grep vending"
}

frida_on() {
  local s; s=$(find_serial)
  [ -n "$(play_alive "$s")" ] \
    || die "Play 商店没在跑，frida 先起会让 Play 启动超时（先跑 ./mumu.sh play）"
  adb -s "$s" shell "pkill -f frida-server" 2>/dev/null || true
  adb -s "$s" shell "nohup /data/local/tmp/frida-server -D >/dev/null 2>&1 &"
  sleep 2
  adb -s "$s" shell "ps -A | grep -q frida-server" && log "✅ frida-server 已起" || die "frida-server 起不来"
}

frida_off() { local s; s=$(find_serial); adb -s "$s" shell "pkill -f frida-server" 2>/dev/null; log "frida-server 已停"; }

# ---- 业务 ----
# pro0.py --check 有两处会坏顺序：先把 frida-server 起起来、中途又把设备代理清成 :0。
# 所以这里不直接跑它，而是自己按正确顺序做：代理 → Play → frida → 检查 → 恢复代理，
# 最后再用 pro0.py --check 校验（此时各件已就位，它能通过）。
do_check() {
  local s; s=$(find_serial)
  # 1. 保证代理在
  if [ "$(adb -s "$s" shell "settings get global http_proxy" | tr -d '\r')" != "10.0.2.2:$FORWARD_PORT" ]; then
    net_on
  fi
  # 2. Play 先起（frida 后起）
  play_up
  # 3. 再起 frida
  frida_on
  # 4. pro0.py 自检（会清代理，跑完立即恢复）
  ( cd "$WORK" && "$PY" pro0.py --check --serial "$s" )
  local rc=$?
  adb -s "$s" shell "settings put global http_proxy 10.0.2.2:$FORWARD_PORT" >/dev/null
  log "设备代理已恢复 10.0.2.2:$FORWARD_PORT"
  return $rc
}

do_run18m() {
  local s; s=$(find_serial)
  # 代理必须先就位，否则 Play / 收银台走直连拿不到美区 offer
  [ "$(adb -s "$s" shell "settings get global http_proxy" | tr -d '\r')" = "10.0.2.2:$FORWARD_PORT" ] || net_on
  play_up
  frida_on
  ( cd "$WORK" && "$PY" pro0.py --account "current@device" --no-add --force \
      --sku g1.2tb.ai.18months_eft --serial "$s" )
  local rc=$?
  # pro0.py 内部会清设备代理，跑完恢复
  adb -s "$s" shell "settings put global http_proxy 10.0.2.2:$FORWARD_PORT" >/dev/null
  log "设备代理已恢复 10.0.2.2:$FORWARD_PORT"
  return $rc
}

do_shot() {
  local s out; s=$(find_serial); out="/tmp/mumu-$(date +%H%M%S).png"
  adb -s "$s" exec-out screencap -p > "$out" && echo "$out"
}

# ---- dispatch ----
cmd="${1:-}"; sub="${2:-}"
case "$cmd" in
  serial) find_serial ;;
  boot)   boot; wait_boot ;;
  reset)  do_reset ;;
  proxy)  case "$sub" in up) proxy_up ;; ip) proxy_ip ;; down) proxy_down ;; *) die "proxy up|ip|down" ;; esac ;;
  net)    case "$sub" in on) net_on ;; off) net_off ;; *) die "net on|off" ;; esac ;;
  play)   play_up ;;
  frida)  case "$sub" in on) frida_on ;; off) frida_off ;; *) die "frida on|off" ;; esac ;;
  check)  do_check ;;
  run-18m) do_run18m ;;
  shot)   do_shot ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
