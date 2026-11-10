#!/usr/bin/env bash
# Manage the SONiC VS virtual machine (QEMU) on this WSL2 host.
#
# KVM is NOT usable on this machine: the Windows hypervisor does not expose
# nested virtualization to WSL2 (dmesg: "Hyper-V: Nested features: 0x0",
# kvm_amd cannot be inserted; /dev/kvm exists but KVM_CREATE_VM -> ENODEV).
# See https://github.com/microsoft/WSL/issues/13262. QEMU therefore runs
# TCG multi-threaded emulation: first boot (ONIE install) takes ~20-60 min,
# later boots a few minutes. KVM is auto-detected on every start, so the
# script upgrades itself if nested virt ever starts working.
#
# Usage:  run-vs.sh {start|stop|status|console|wait-ssh|monitor <cmd>}
# Env:    IMG=<image> MEM_MB=<mb> SMP=<cpus> SSH_PORT=<port>
#
# Console login (serial or ssh): admin / YourPaSsWoRd
set -euo pipefail
cd "$(dirname "$0")"

IMG=${IMG:-sonic-vs.img}
MEM_MB=${MEM_MB:-4096}
SMP=${SMP:-4}
# Bind 0.0.0.0 by default so Windows can reach the VM via the WSL IP:
# WSL's localhostForwarding does not carry this port (the local Clash proxy
# interferes -- "localhost 代理配置... NAT 模式下的 WSL 不支持"), so
# 127.0.0.1-only binding would lock out Windows-side access. The machine
# sits behind a NAT router, so 0.0.0.0 does not expose the VM to the LAN.
SSH_BIND=${SSH_BIND:-0.0.0.0}
SSH_PORT=${SSH_PORT:-10022}
PIDFILE=qemu.pid
CONSOLE_LOG=console.log
MONITOR_SOCK=qemu-monitor.sock
SERIAL_SOCK=qemu-serial.sock

qemu_pid() { [ -f "$PIDFILE" ] && cat "$PIDFILE" 2>/dev/null || true; }
is_running() { local p; p=$(qemu_pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# The official sonic-vs.img is a QCOW2 image despite the .img name; probe
# the real format instead of assuming raw (format=raw on a qcow2 file boots
# straight into "No bootable device").
img_format() {
    qemu-img info --output=json "$IMG" | \
        python3 -c 'import json,sys; print(json.load(sys.stdin)["format"])'
}

# Probe KVM by actually creating a throwaway VM: on this host /dev/kvm
# exists but VM creation fails, so testing writability alone would lie.
accel_args() {
    if qemu-system-x86_64 -machine pc,accel=kvm -display none -nodefaults \
         -m 32 -S -daemonize -pidfile /tmp/vs-kvm-probe.$$ 2>/dev/null; then
        rm -f "/tmp/vs-kvm-probe.$$"
        echo "-enable-kvm -cpu host"
    else
        echo "-accel tcg,thread=multi -cpu max"
    fi
}

# Send one QEMU monitor command over the unix monitor socket.
mon() {
    python3 - "$MONITOR_SOCK" "$1" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(5)
s.connect(sys.argv[1]); time.sleep(0.2)
try: s.recv(4096)
except OSError: pass
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(0.3)
try: print(s.recv(65536).decode(errors="replace"))
except OSError: pass
PY
}

cmd_start() {
    if is_running; then echo "already running (pid $(qemu_pid))"; exit 0; fi
    [ -f "$IMG" ] || { echo "image $IMG not found -- run ./download-vs.sh first" >&2; exit 1; }
    local accel; accel=$(accel_args)
    echo "accel: $accel"
    echo "image format: $(img_format)"
    qemu-system-x86_64 $accel \
        -m "$MEM_MB" -smp "$SMP" \
        -drive file="$IMG",format=$(img_format),if=virtio \
        -device virtio-rng-pci \
        -netdev user,id=net0,hostfwd=tcp:${SSH_BIND}:${SSH_PORT}-:22 \
        -device e1000,netdev=net0 \
        -display none \
        -chardev socket,id=ser0,path="$SERIAL_SOCK",server=on,wait=off,logfile="$CONSOLE_LOG" \
        -serial chardev:ser0 \
        -monitor unix:"$MONITOR_SOCK",server,nowait \
        -daemonize -pidfile "$PIDFILE"
    echo "started (pid $(qemu_pid)); console log: $CONSOLE_LOG"
    echo "ssh (from WSL):     ssh -p $SSH_PORT admin@127.0.0.1"
    echo "ssh (from Windows): ssh -p $SSH_PORT admin@$(ip -4 addr show eth0 | awk "/inet /{print \$2}" | cut -d/ -f1)"
    echo "default password: YourPaSsWoRd"
}

cmd_stop() {
    local p; p=$(qemu_pid)
    [ -n "$p" ] || { echo "not running"; exit 0; }
    kill -0 "$p" 2>/dev/null || { echo "not running (stale pidfile)"; rm -f "$PIDFILE"; exit 0; }
    echo "powering down (graceful, up to 90s -- TCG guest shutdown is slow)..."
    mon system_powerdown >/dev/null 2>&1 || true
    for _ in $(seq 1 18); do
        kill -0 "$p" 2>/dev/null || { echo "stopped"; rm -f "$PIDFILE"; exit 0; }
        sleep 5
    done
    # powerdown needs a running OS; if nothing responded (no OS booted, or
    # the guest hung), ask QEMU itself to quit cleanly.
    echo "no response to powerdown, sending monitor quit"
    mon quit >/dev/null 2>&1 || true
    for _ in $(seq 1 2); do
        kill -0 "$p" 2>/dev/null || { echo "stopped"; rm -f "$PIDFILE"; exit 0; }
        sleep 5
    done
    echo "still alive, sending SIGTERM"
    kill "$p" 2>/dev/null || true
    sleep 5
    kill -0 "$p" 2>/dev/null && { kill -9 "$p" 2>/dev/null || true; }
    rm -f "$PIDFILE"
    echo "stopped"
}

cmd_status() {
    if is_running; then
        echo "running (pid $(qemu_pid))"
        ps -o pid,etime,pcpu,rss,args -p "$(qemu_pid)" | tail -1 | cut -c1-120
    else
        echo "not running"
    fi
    # match the port on any bind address (hostfwd binds $SSH_BIND = 0.0.0.0)
    if ss -ltn 2>/dev/null | grep -q ":$SSH_PORT "; then
        echo "ssh port :$SSH_PORT: listening"
    else
        echo "ssh port :$SSH_PORT: not listening"
    fi
    if [ -f "$CONSOLE_LOG" ]; then
        echo "--- last console lines ---"
        tail -n 6 "$CONSOLE_LOG" | cut -c1-120
    fi
}

cmd_console() {
    [ -S "$SERIAL_SOCK" ] || { echo "serial socket $SERIAL_SOCK missing -- VM not started?" >&2; exit 1; }
    echo "== serial console (Ctrl-] to quit) =="
    python3 - "$SERIAL_SOCK" <<'PY'
import socket, sys, threading
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])

def pump():
    while True:
        d = s.recv(4096)
        if not d: break
        sys.stdout.buffer.write(d); sys.stdout.flush()

t = threading.Thread(target=pump, daemon=True); t.start()
try:
    while True:
        d = sys.stdin.buffer.read(1)
        if d == b'\x1d': break   # Ctrl-]
        if not d: break
        s.sendall(d)
except KeyboardInterrupt:
    pass
PY
}

cmd_wait_ssh() {
    local i=0
    echo "waiting for sshd on 127.0.0.1:$SSH_PORT (first boot runs the ONIE install -> slow under TCG)"
    # A plain /dev/tcp probe is not enough: QEMU's hostfwd accepts the
    # host-side connection before the guest sshd is up. Keep polling until
    # a real SSH login succeeds — and abort as soon as the QEMU process is
    # gone (guest powered down mid-wait), instead of looping forever.
    until sshpass -p "${VS_SSH_PASS:-YourPaSsWoRd}" ssh \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -o LogLevel=ERROR \
            -p "$SSH_PORT" admin@127.0.0.1 true 2>/dev/null; do
        i=$((i+1))
        if ! is_running; then
            echo "qemu process gone (guest powered down?) -- aborting wait" >&2
            rm -f "$PIDFILE"
            exit 1
        fi
        if [ $((i % 12)) -eq 0 ]; then
            echo "  ... $((i*10))s elapsed; console tail: $(tail -c 300 "$CONSOLE_LOG" 2>/dev/null | tr '\n' ' ' | tail -c 100)"
        fi
        sleep 10
    done
    echo "ssh is up after ~$((i*10+10))s"
}

case "${1:-}" in
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    status)   cmd_status ;;
    console)  cmd_console ;;
    wait-ssh) cmd_wait_ssh ;;
    monitor)  shift; mon "$*" ;;
    *) echo "usage: $0 {start|stop|status|console|wait-ssh|monitor <qemu-monitor-cmd>}"; exit 1 ;;
esac
