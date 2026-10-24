#!/usr/bin/env bash
# =============================================================
# mini-linux.sh — 在当前目录启动一个极简微型 Linux 并开启 SSH (bash 版)
#
# 注意: 受限沙箱环境 (禁止 setuid/setgroups/宿主 pty) 请改用 mini-linux.py,
#       它使用用户态 asyncssh 服务端, 无需权限切换, 兼容性更好。
#
# 用法:
#   ./mini-linux.sh setup    # 首次: 下载 Alpine rootfs 并配置 demo 用户 (需联网)
#   ./mini-linux.sh start    # 启动 SSH 服务 (默认端口 2222, 可用 PORT=xxxx 覆盖)
#   ./mini-linux.sh start-fg # 前台启动 (守护模式失败时使用, Ctrl+C 停止)
#   ./mini-linux.sh stop     # 停止 SSH 服务并清理挂载
#   ./mini-linux.sh shell    # 直接进入微型 Linux 的 shell
#   ./mini-linux.sh status   # 查看运行状态
#
# 连接方式:
#   ssh demo@127.0.0.1 -p 2222      # 用户名: demo  密码: demo
#
# 原理:
#   - 在 ./mini-linux/rootfs 放置一个 Alpine Linux 微型根文件系统 (~10MB)
#   - root 用户: 用 chroot 运行; 普通用户: 自动安装/下载 proot 运行
#   - 在其中运行 dropbear (轻量 SSH 服务端), 监听宿主机端口
#   - 主机密钥存放在 rootfs 的 /var/lib/keys (部分环境禁止写 /etc/dropbear)
# =============================================================
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mini-linux"
ROOTFS="$BASE_DIR/rootfs"
STATE="$BASE_DIR/state"
PORT="${PORT:-2222}"
DEMO_USER="demo"
DEMO_PASS="demo"
KEY_DIR_INNER="/var/lib/keys"          # rootfs 内的主机密钥目录
KEY_ED25519="$KEY_DIR_INNER/dropbear_ed25519_host_key"

ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_BRANCH="v3.20"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  AARCH="x86_64" ;;
  aarch64) AARCH="aarch64" ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }

# ---------- proot (非 root 模式) ----------
PROOT="$BASE_DIR/proot"
ensure_proot() {
  if command -v proot >/dev/null 2>&1; then
    PROOT="$(command -v proot)"
    return 0
  fi
  if [ -x "$PROOT" ]; then return 0; fi
  # 优先用系统包管理器安装
  if command -v apt-get >/dev/null 2>&1; then
    c_cyan "[*] 尝试通过 apt 安装 proot..."
    if [ "$(id -u)" = "0" ]; then
      apt-get install -y proot >/dev/null 2>&1 || true
    else
      sudo -n apt-get install -y proot >/dev/null 2>&1 || true
    fi
    command -v proot >/dev/null 2>&1 && { PROOT="$(command -v proot)"; return 0; }
  fi
  # 回退: 下载静态版
  c_cyan "[*] 未找到 proot, 正在下载静态版本..."
  mkdir -p "$BASE_DIR"
  local ok=0 url
  for url in \
    "https://github.com/proot-me/proot-static-build/releases/download/v5.1.0/proot-v5.1.0-${AARCH}-static" \
    "https://github.com/proot-me/proot/releases/download/v6.1.0/proot-v6.1.0-${AARCH}-static"; do
    if curl -fsSL "$url" -o "$PROOT"; then ok=1; break; fi
  done
  [ "$ok" = "1" ] || { c_red "[!] proot 获取失败, 非 root 模式无法继续"; exit 1; }
  chmod +x "$PROOT"
  c_green "[+] proot 下载完成"
}

# 在微型 Linux 内执行命令 (自动选择 chroot / proot)
run_inner() {
  local cmd="$1"
  if [ "$(id -u)" = "0" ]; then
    # 挂载必要的虚拟文件系统 (尽力而为, 失败不中断)
    mkdir -p "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev/pts"
    mountpoint -q "$ROOTFS/dev"     || mount --bind /dev "$ROOTFS/dev"     2>/dev/null || true
    mountpoint -q "$ROOTFS/dev/pts" || mount --bind /dev/pts "$ROOTFS/dev/pts" 2>/dev/null || true
    mountpoint -q "$ROOTFS/proc"    || mount -t proc  proc  "$ROOTFS/proc" 2>/dev/null || true
    mountpoint -q "$ROOTFS/sys"     || mount --bind /sys "$ROOTFS/sys"     2>/dev/null || true
    chroot "$ROOTFS" /bin/sh -c "$cmd"
  else
    ensure_proot
    "$PROOT" -0 -R "$ROOTFS" /bin/sh -c "$cmd"
  fi
}

cleanup_mounts() {
  if [ "$(id -u)" = "0" ]; then
    mountpoint -q "$ROOTFS/dev/pts" && umount "$ROOTFS/dev/pts" 2>/dev/null || true
    mountpoint -q "$ROOTFS/proc"    && umount "$ROOTFS/proc"    2>/dev/null || true
    mountpoint -q "$ROOTFS/sys"     && umount "$ROOTFS/sys"     2>/dev/null || true
    mountpoint -q "$ROOTFS/dev"     && umount "$ROOTFS/dev"     2>/dev/null || true
  fi
}

# 直接编辑 rootfs 账号文件创建用户 (chpasswd 不可用时的降级方案)
create_user_by_files() {
  local hash="" uid=1000
  if command -v openssl >/dev/null 2>&1; then
    hash="$(openssl passwd -6 "$DEMO_PASS")"
  else
    hash="$(run_inner "busybox cryptpw -m sha512 '$DEMO_PASS'" 2>/dev/null || true)"
  fi
  [ -n "$hash" ] || { c_red "[!] 无法生成密码哈希"; exit 1; }
  grep -q "^$DEMO_USER:" "$ROOTFS/etc/passwd" || \
    echo "$DEMO_USER:x:$uid:$uid:$DEMO_USER:/home/$DEMO_USER:/bin/ash" >> "$ROOTFS/etc/passwd"
  grep -q "^$DEMO_USER:" "$ROOTFS/etc/group" || \
    echo "$DEMO_USER:x:$uid:" >> "$ROOTFS/etc/group"
  grep -q "^$DEMO_USER:" "$ROOTFS/etc/shadow" || \
    echo "$DEMO_USER:$hash:20000:0:99999:7:::" >> "$ROOTFS/etc/shadow"
}

# ---------- setup ----------
do_setup() {
  mkdir -p "$BASE_DIR"
  if [ ! -e "$ROOTFS/etc/alpine-release" ]; then
    c_cyan "[*] 正在获取 Alpine minirootfs ($AARCH) 下载地址..."
    local listing fname url
    listing="$(curl -fsSL "$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$AARCH/")" || {
      c_red "[!] 无法访问 Alpine 镜像, 请检查网络"; exit 1; }
    fname="$(echo "$listing" | grep -o "alpine-minirootfs-[0-9.]*-$AARCH.tar.gz" | sort -Vu | tail -1)"
    [ -n "$fname" ] || { c_red "[!] 未能解析下载文件名"; exit 1; }
    url="$ALPINE_MIRROR/$ALPINE_BRANCH/releases/$AARCH/$fname"
    c_cyan "[*] 下载 $url"
    curl -fsSL "$url" -o "$BASE_DIR/rootfs.tar.gz"
    mkdir -p "$ROOTFS"
    tar -xzf "$BASE_DIR/rootfs.tar.gz" --no-same-owner -C "$ROOTFS"
    rm -f "$BASE_DIR/rootfs.tar.gz"
    c_green "[+] rootfs 解压完成"
  else
    c_green "[+] rootfs 已存在, 跳过下载"
  fi

  # 保证 DNS 可用
  if [ -f /etc/resolv.conf ]; then
    cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || true
  fi
  mkdir -p "$ROOTFS/var/run" "$ROOTFS/root" "$ROOTFS/home/$DEMO_USER" "$ROOTFS$KEY_DIR_INNER"

  c_cyan "[*] 安装 dropbear (轻量 SSH 服务端)..."
  run_inner "apk update --quiet && apk add --no-cache --quiet dropbear"

  c_cyan "[*] 创建用户 $DEMO_USER / $DEMO_PASS ..."
  if ! run_inner "id $DEMO_USER >/dev/null 2>&1 || adduser -D $DEMO_USER"; then
    c_cyan "[*] adduser 不可用, 直接编辑账号文件..."
    create_user_by_files
  fi
  if ! run_inner "echo '$DEMO_USER:$DEMO_PASS' | chpasswd" 2>/dev/null; then
    c_cyan "[*] chpasswd 不可用, 直接编辑账号文件..."
    create_user_by_files
  fi
  if ! run_inner "chown -R $DEMO_USER:$DEMO_USER /home/$DEMO_USER" 2>/dev/null; then
    # 某些受限环境禁止 chown, 放宽权限兜底
    chmod 777 "$ROOTFS/home/$DEMO_USER" 2>/dev/null || true
  fi

  # 生成 SSH 主机密钥 (放在 /var/lib/keys, 避免写入受限的 /etc/dropbear)
  c_cyan "[*] 生成 SSH 主机密钥..."
  run_inner "[ -f $KEY_ED25519 ] || dropbearkey -t ed25519 -f $KEY_ED25519"

  echo "$PORT" > "$STATE"
  c_green "[+] 初始化完成! 运行 ./mini-linux.sh start 启动 SSH 服务"
}

# ---------- start (守护模式) ----------
do_start() {
  [ -e "$ROOTFS/etc/alpine-release" ] || { c_red "[!] 尚未初始化, 请先运行 ./mini-linux.sh setup"; exit 1; }

  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    c_red "[!] 端口 $PORT 已被占用, 可用 PORT=其他端口 ./mini-linux.sh start"; exit 1
  fi

  echo "$PORT" > "$STATE"
  # -r 指定主机密钥; 默认守护模式后台运行
  if ! run_inner "/usr/sbin/dropbear -r $KEY_ED25519 -p 0.0.0.0:$PORT"; then
    c_red "[!] dropbear 启动失败, 可尝试: ./mini-linux.sh start-fg"
    exit 1
  fi

  sleep 0.5
  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    print_started
  else
    c_red "[!] 端口未监听 (部分环境禁止守护进程), 请尝试: ./mini-linux.sh start-fg"
    exit 1
  fi
}

# ---------- start-fg (前台模式) ----------
do_start_fg() {
  [ -e "$ROOTFS/etc/alpine-release" ] || { c_red "[!] 尚未初始化, 请先运行 ./mini-linux.sh setup"; exit 1; }
  echo "$PORT" > "$STATE"
  c_cyan "[*] 前台运行 dropbear (Ctrl+C 停止), 连接: ssh $DEMO_USER@127.0.0.1 -p $PORT"
  run_inner "/usr/sbin/dropbear -r $KEY_ED25519 -p 0.0.0.0:$PORT -F -E"
}

print_started() {
  c_green "[+] 微型 Linux SSH 服务已启动!"
  echo
  echo "    连接命令:  ssh $DEMO_USER@127.0.0.1 -p $PORT"
  echo "    用户名:    $DEMO_USER"
  echo "    密码:      $DEMO_PASS"
  echo
  echo "    停止服务:  ./mini-linux.sh stop"
}

# ---------- stop ----------
do_stop() {
  local pidfile="$ROOTFS/var/run/dropbear.pid"
  if [ -f "$pidfile" ]; then
    local pid
    pid="$(cat "$pidfile")"
    kill "$pid" 2>/dev/null && c_green "[+] 已停止 dropbear (pid $pid)" || c_cyan "[*] dropbear 未在运行"
    rm -f "$pidfile"
  else
    # 兜底: 按名称查找
    pkill -f "dropbear.*-p 0.0.0.0:$PORT" 2>/dev/null && c_green "[+] 已停止 dropbear" || c_cyan "[*] 没有运行中的服务"
  fi
  cleanup_mounts
}

# ---------- shell ----------
do_shell() {
  [ -e "$ROOTFS/etc/alpine-release" ] || { c_red "[!] 尚未初始化, 请先运行 ./mini-linux.sh setup"; exit 1; }
  c_cyan "[*] 进入微型 Linux (exit 退出)"
  if [ "$(id -u)" = "0" ]; then
    run_inner "exec /bin/su - $DEMO_USER"
  else
    ensure_proot
    "$PROOT" -0 -R "$ROOTFS" /bin/su - "$DEMO_USER"
  fi
}

# ---------- status ----------
do_status() {
  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    c_green "[运行中] 端口 $PORT  ->  ssh $DEMO_USER@127.0.0.1 -p $PORT (密码 $DEMO_PASS)"
  else
    c_cyan "[未运行] 端口 $PORT 无监听"
  fi
}

case "${1:-help}" in
  setup)    do_setup ;;
  start)    do_start ;;
  start-fg) do_start_fg ;;
  stop)     do_stop ;;
  shell)    do_shell ;;
  status)   do_status ;;
  *)
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
