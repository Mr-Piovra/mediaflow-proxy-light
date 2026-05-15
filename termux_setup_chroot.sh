#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# MediaFlow Proxy Light - Termux CHRoot Setup (Root Required)
# ============================================================
# Requisiti:
#   - Termux da F-Droid
#   - Root permanente via Magisk
#   - proot-distro ubuntu già installato
#
# Dopo il setup, avvio con:
#   mediaflow
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
step() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ─── Costanti ───────────────────────────────────────────────
PROOT_ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
CHROOT_LINK="/data/local/mediaflow-rootfs"

echo ""
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  MediaFlow Proxy Light - CHRoot Setup        ${NC}"
echo -e "${CYAN}  Xiaomi Mi 9 Lite | arm64 | Magisk Root      ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════${NC}"
echo ""

# ─── PHASE 1: Prerequisiti ─────────────────────────────────
step "Phase 1/9: Verifica prerequisiti"

if ! su -c "echo root_ok" >/dev/null 2>&1; then
    err "Root non disponibile. Assicurati che Magisk sia installato."
fi
log "Root Magisk disponibile."

ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    err "Architettura non supportata: $ARCH. Richiesta aarch64."
fi
log "Architettura: $ARCH"

if [ ! -d "$PROOT_ROOTFS" ]; then
    warn "Rootfs Ubuntu proot-distro non trovato in: $PROOT_ROOTFS"
    pkg install -y proot-distro wget curl screen 2>/dev/null || true
    proot-distro install ubuntu || err "Installazione proot-distro Ubuntu fallita."
fi
log "Rootfs Ubuntu trovato: $PROOT_ROOTFS"

if ! command -v screen >/dev/null 2>&1; then
    pkg install -y screen
fi
log "screen disponibile."

# ─── PHASE 2: Symlink rootfs ────────────────────────────────
step "Phase 2/9: Configurazione percorso CHRoot"

su -c "mkdir -p /data/local" 2>/dev/null || true

if [ -L "$CHROOT_LINK" ]; then
    EXISTING_TARGET=$(su -c "readlink -f '$CHROOT_LINK'" 2>/dev/null || echo "")
    if [ "$EXISTING_TARGET" = "$(realpath "$PROOT_ROOTFS")" ]; then
        log "Symlink CHRoot già corretto."
    else
        su -c "rm '$CHROOT_LINK' && ln -s '$PROOT_ROOTFS' '$CHROOT_LINK'"
        log "Symlink aggiornato."
    fi
elif [ -d "$CHROOT_LINK" ]; then
    su -c "mv '$CHROOT_LINK' '${CHROOT_LINK}.bak.$(date +%s)' && ln -s '$PROOT_ROOTFS' '$CHROOT_LINK'"
    log "Symlink creato (backup salvato)."
else
    su -c "ln -s '$PROOT_ROOTFS' '$CHROOT_LINK'"
    log "Symlink creato."
fi

# ─── PHASE 3: Directory mount points ───────────────────────
step "Phase 3/9: Creazione directory mount points"

for DIR in proc sys dev dev/pts sdcard; do
    su -c "mkdir -p '${CHROOT_LINK}/${DIR}'"
    log "  ✓ ${CHROOT_LINK}/${DIR}"
done

# ─── PHASE 4: Test mount + verifica CHRoot ──────────────────
step "Phase 4/9: Test mount e sanity check CHRoot"

su -c "setenforce 0" 2>/dev/null || warn "setenforce 0 fallito"

do_mount() {
    local OPTS="$1"; local SRC="$2"; local DST="$3"
    local OUT
    OUT=$(su -c "mountpoint -q '$DST' && echo already_mounted || mount $OPTS '$SRC' '$DST'" 2>&1)
    if ! echo "$OUT" | grep -q already_mounted; then
        [ $? -ne 0 ] && warn "Mount fallito per '$DST': $OUT"
    fi
}

do_mount "-t proc"   "proc"   "${CHROOT_LINK}/proc"
do_mount "-t sysfs"  "sysfs"  "${CHROOT_LINK}/sys"

su -c "mountpoint -q '${CHROOT_LINK}/dev' || mount --bind /dev '${CHROOT_LINK}/dev'" 2>/dev/null || true
su -c "mkdir -p '${CHROOT_LINK}/dev/shm'" 2>/dev/null || true

do_mount "-t devpts" "devpts" "${CHROOT_LINK}/dev/pts"
do_mount "-t tmpfs -o size=256M" "tmpfs" "${CHROOT_LINK}/dev/shm"

CHROOT_TARGET=$(su -c "readlink -f '${CHROOT_LINK}'" 2>/dev/null || echo "$PROOT_ROOTFS")

CHROOT_OUT=$(su -c "chroot '$CHROOT_TARGET' /bin/uname -m" 2>&1)
if [ "$CHROOT_OUT" != "aarch64" ]; then
    err "CHRoot test fallito: '$CHROOT_OUT'"
fi
log "CHRoot funzionante."

# ─── PHASE 5: Rete Android (GID 3003 inet) ──────────────────
step "Phase 5/9: Configurazione Android Network (GID 3003)"

su -c "chroot '$CHROOT_TARGET' /bin/bash -c '
    export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"
    if ! grep -q \"^inet_android:\" /etc/group 2>/dev/null; then
        echo \"inet_android:x:3003:root\" >> /etc/group
    fi
    if ! grep -q \"^inet_android:.*root\" /etc/group 2>/dev/null; then
        sed -i \"s/^inet_android:x:3003:/inet_android:x:3003:root/\" /etc/group
    fi
'"
log "Gruppo inet_android (GID 3003) configurato."

# ─── PHASE 6: DNS injection ─────────────────────────────────
step "Phase 6/9: Configurazione DNS"

DNS1=$(getprop net.dns1 2>/dev/null || echo "1.1.1.1")
DNS2=$(getprop net.dns2 2>/dev/null || echo "8.8.8.8")
[ -z "$DNS1" ] && DNS1="1.1.1.1"
[ -z "$DNS2" ] && DNS2="8.8.8.8"

su -c "rm -f '${CHROOT_TARGET}/etc/resolv.conf' && echo -e 'nameserver ${DNS1}\nnameserver ${DNS2}' > '${CHROOT_TARGET}/etc/resolv.conf'"
log "resolv.conf configurato: $DNS1, $DNS2"

# ─── PHASE 7: Installazione Mediaflow Proxy Light ───────────
step "Phase 7/9: Installazione MediaFlow Proxy Light"

su -c "chroot '$CHROOT_TARGET' /bin/bash -c '
    export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"
    export DEBIAN_FRONTEND=noninteractive
    
    apt-get update -yqq && apt-get install -yqq wget curl ca-certificates login
    
    echo \"Download mediaflow-proxy-light-linux-aarch64...\"
    wget -q --show-progress https://github.com/mhdzumair/MediaFlow-Proxy-Light/releases/latest/download/mediaflow-proxy-light-linux-aarch64 -O /usr/local/bin/mediaflow-proxy-light
    chmod +x /usr/local/bin/mediaflow-proxy-light
    
    if [ ! -f /etc/mediaflow.toml ]; then
        echo \"Scaricamento configurazione base in /etc/mediaflow.toml...\"
        wget -q https://raw.githubusercontent.com/mhdzumair/MediaFlow-Proxy-Light/main/config-example.toml -O /etc/mediaflow.toml
        # Imposta host a 0.0.0.0 e port a 8888 come default
        sed -i \"s/^host = .*/host = \\\"0.0.0.0\\\"/\" /etc/mediaflow.toml
        sed -i \"s/^port = .*/port = 8888/\" /etc/mediaflow.toml
    fi
'"
log "MediaFlow Proxy Light installato in /usr/local/bin/mediaflow-proxy-light."

# ─── PHASE 8: Script di avvio interno al CHRoot ─────────────
step "Phase 8/9: Creazione mediaflow_chroot_start.sh"

su -c "cat > '${CHROOT_TARGET}/root/mediaflow_chroot_start.sh'" << 'CHROOT_START_EOF'
#!/bin/bash
set -u

export HOME=/root
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/mediaflow.log"

# Rotazione log
if [ -f "$LOG_FILE" ]; then
    tail -n 1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi
touch "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

# I permessi di rete GID 3003 vengono iniettati direttamente da 'su -G 3003' nel launcher Termux

echo "=================================================="
echo "[$(date '+%Y-%m-%d %H:%M:%S')] MediaFlow Proxy Light Avvio"
echo "=================================================="

pkill -9 -f "mediaflow-proxy-light" 2>/dev/null || true
sleep 1

# Se la password API non è definita nell'ambiente, impostiamone una di default
export APP__AUTH__API_PASSWORD="${APP__AUTH__API_PASSWORD:-mediaflow_secret}"

echo "Avvio MediaFlow Proxy Light..."
if ! CONFIG_PATH=/etc/mediaflow.toml /usr/local/bin/mediaflow-proxy-light; then
    echo "[CRITICAL] MediaFlow Proxy ha crashato!"
    exit 1
fi
CHROOT_START_EOF

su -c "chmod +x '${CHROOT_TARGET}/root/mediaflow_chroot_start.sh'"
log "mediaflow_chroot_start.sh scritto e reso eseguibile."

# ─── PHASE 9: Comandi Termux ────────────────────────────────
step "Phase 9/9: Creazione comandi Termux"

CHROOT_ROOTFS_PATH="$CHROOT_TARGET"

# ── mediaflow ───────────────────────────────────────────────
cat > "$PREFIX/bin/mediaflow" << MEDIAFLOW_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="${CHROOT_ROOTFS_PATH}"
TERMUX_LOG="\$HOME/.mediaflow_screen.log"

LOCAL_IP=\$(ip route get 1.1.1.1 2>/dev/null | awk '{print \$7}')
[ -z "\$LOCAL_IP" ] && LOCAL_IP=\$(ifconfig wlan0 2>/dev/null | grep 'inet ' | awk '{print \$2}')
[ -z "\$LOCAL_IP" ] && LOCAL_IP="localhost"

if screen -list 2>/dev/null | grep -q "[.]mediaflow[[:space:]]"; then
    echo "MediaFlow è già in esecuzione."
    exit 0
fi

echo "Avvio MediaFlow Proxy Light (CHRoot mode)..."
echo "   Indirizzo: http://\${LOCAL_IP}:8888"
echo "   Log:       mediaflow-logs"
echo "   Stop:      mediaflow-stop"
echo ""

DNS1=\$(getprop net.dns1 2>/dev/null || echo "1.1.1.1")
DNS2=\$(getprop net.dns2 2>/dev/null || echo "8.8.8.8")
su -c "rm -f '\${ROOTFS}/etc/resolv.conf' && echo -e 'nameserver \${DNS1}\nnameserver \${DNS2}' > '\${ROOTFS}/etc/resolv.conf'" 2>/dev/null || true

su -c "
    mountpoint -q '\${ROOTFS}/proc'    || mount -t proc proc '\${ROOTFS}/proc'
    mountpoint -q '\${ROOTFS}/sys'     || mount -t sysfs sysfs '\${ROOTFS}/sys'
    mountpoint -q '\${ROOTFS}/dev'     || mount --bind /dev '\${ROOTFS}/dev'
    mkdir -p '\${ROOTFS}/dev/shm' 2>/dev/null || true
    mountpoint -q '\${ROOTFS}/dev/pts' || mount -t devpts devpts '\${ROOTFS}/dev/pts'
    mountpoint -q '\${ROOTFS}/dev/shm' || mount -t tmpfs -o size=256M tmpfs '\${ROOTFS}/dev/shm'
    mountpoint -q '\${ROOTFS}/sdcard'  || mount --bind /sdcard '\${ROOTFS}/sdcard' 2>/dev/null || true
    setenforce 0 2>/dev/null || true
" 2>/dev/null

screen -L -Logfile "\$TERMUX_LOG" -dmS mediaflow \
    su -G 3003 -c "chroot '\${ROOTFS}' /root/mediaflow_chroot_start.sh"

sleep 2
echo "MediaFlow avviato in background."
MEDIAFLOW_EOF
chmod +x "$PREFIX/bin/mediaflow"
log "Creato: mediaflow"

# ── mediaflow-stop ──────────────────────────────────────────
cat > "$PREFIX/bin/mediaflow-stop" << STOP_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="${CHROOT_ROOTFS_PATH}"

echo "Stop MediaFlow Proxy e unmount filesystem..."
su -c "
    pkill -9 -f 'mediaflow-proxy-light' 2>/dev/null || true
    pkill -9 -f 'chroot.*mediaflow' 2>/dev/null || true
    sleep 1
    umount '\${ROOTFS}/dev/shm'  2>/dev/null || true
    umount '\${ROOTFS}/dev/pts'  2>/dev/null || true
    umount '\${ROOTFS}/dev'      2>/dev/null || true
    umount '\${ROOTFS}/sys'      2>/dev/null || true
    umount '\${ROOTFS}/proc'     2>/dev/null || true
    umount '\${ROOTFS}/sdcard'   2>/dev/null || true
    setenforce 1 2>/dev/null || true
" 2>/dev/null

screen -X -S mediaflow quit 2>/dev/null || true
echo "Fermato."
STOP_EOF
chmod +x "$PREFIX/bin/mediaflow-stop"
log "Creato: mediaflow-stop"

# ── mediaflow-logs ──────────────────────────────────────────
cat > "$PREFIX/bin/mediaflow-logs" << LOGS_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="${CHROOT_ROOTFS_PATH}"
LOG_FILE="\${ROOTFS}/var/log/mediaflow.log"

if [ ! -f "\$LOG_FILE" ]; then
    echo "Nessun log trovato."
    exit 0
fi
su -c "tail -n 100 -f '\$LOG_FILE'" | cat
LOGS_EOF
chmod +x "$PREFIX/bin/mediaflow-logs"
log "Creato: mediaflow-logs"

# ── mediaflow-update ────────────────────────────────────────
cat > "$PREFIX/bin/mediaflow-update" << UPDATE_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="${CHROOT_ROOTFS_PATH}"

echo "Aggiornamento MediaFlow Proxy Light..."
mediaflow-stop 2>/dev/null || true

su -c "chroot '\${ROOTFS}' /bin/bash -c '
    echo \"Download nuova versione...\"
    wget -q --show-progress https://github.com/mhdzumair/MediaFlow-Proxy-Light/releases/latest/download/mediaflow-proxy-light-linux-aarch64 -O /usr/local/bin/mediaflow-proxy-light
    chmod +x /usr/local/bin/mediaflow-proxy-light
    echo \"[OK] Aggiornamento completato.\"
'"
mediaflow
UPDATE_EOF
chmod +x "$PREFIX/bin/mediaflow-update"
log "Creato: mediaflow-update"

# ── mediaflow-shell ─────────────────────────────────────────
cat > "$PREFIX/bin/mediaflow-shell" << SHELL_EOF
#!/data/data/com.termux/files/usr/bin/bash
ROOTFS="${CHROOT_ROOTFS_PATH}"

echo "Entrata nel CHRoot Ubuntu (root)... Usa 'exit' per uscire."
su -c "
    mountpoint -q '\${ROOTFS}/proc' || mount -t proc proc '\${ROOTFS}/proc'
    mountpoint -q '\${ROOTFS}/sys'  || mount -t sysfs sysfs '\${ROOTFS}/sys'
    mountpoint -q '\${ROOTFS}/dev'  || mount --bind /dev '\${ROOTFS}/dev'
    chroot '\${ROOTFS}' /bin/bash -c 'export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"; exec /bin/bash'
"
SHELL_EOF
chmod +x "$PREFIX/bin/mediaflow-shell"
log "Creato: mediaflow-shell"

# ── Cleanup umount test ──────────────────────────────────────
su -c "
    umount '${CHROOT_TARGET}/dev/shm'  2>/dev/null || true
    umount '${CHROOT_TARGET}/dev/pts'  2>/dev/null || true
    umount '${CHROOT_TARGET}/dev'      2>/dev/null || true
    umount '${CHROOT_TARGET}/sys'      2>/dev/null || true
    umount '${CHROOT_TARGET}/proc'     2>/dev/null || true
" 2>/dev/null

echo ""
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  MediaFlow Proxy CHRoot Setup Completato!    ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BLUE}Avvia:${NC}      mediaflow"
echo -e "  ${BLUE}Ferma:${NC}      mediaflow-stop"
echo -e "  ${BLUE}Log:${NC}        mediaflow-logs"
echo -e "  ${BLUE}Aggiorna:${NC}   mediaflow-update"
echo -e "  ${BLUE}Shell:${NC}      mediaflow-shell"
echo ""
echo -e "  ${CYAN}Accesso:${NC}    http://localhost:8888"
echo -e "  ${CYAN}Password API:${NC} mediaflow_secret (modifica in /etc/mediaflow.toml)"
echo ""