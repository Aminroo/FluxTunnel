#!/bin/bash

# ===========================
#  SSH Tunnel Setup Script
#  github.com/your-repo
# ===========================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

print_banner() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════╗"
    echo "║      SSH Reverse Tunnel Setup v1.0     ║"
    echo "╚════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() { echo -e "${BLUE}[*]${NC} $1"; }
print_ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
print_err()  { echo -e "${RED}[✗]${NC} $1"; }

# ────────────────────────────────────────────────
ask_mode() {
    echo ""
    echo -e "${BOLD}این سرور کجاست؟${NC}"
    echo "  1) ایران (کلاینت - تانل برقرار می‌کنه)"
    echo "  2) خارج  (سرور  - تانل رو می‌پذیره)"
    echo ""
    read -p "انتخاب [1/2]: " MODE
    [[ "$MODE" != "1" && "$MODE" != "2" ]] && { print_err "انتخاب اشتباه"; exit 1; }
}

# ────────────────────────────────────────────────
setup_server() {
    print_step "تنظیم سرور خارج..."

    # sshd_config
    SSHD="/etc/ssh/sshd_config"

    grep -q "^GatewayPorts" $SSHD \
        && sed -i 's/^GatewayPorts.*/GatewayPorts yes/' $SSHD \
        || echo "GatewayPorts yes" >> $SSHD

    grep -q "^AllowTcpForwarding" $SSHD \
        && sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding yes/' $SSHD \
        || echo "AllowTcpForwarding yes" >> $SSHD

    systemctl restart sshd && print_ok "sshd ریستارت شد"

    # Firewall
    echo ""
    read -p "پورت تانل (پیش‌فرض 20000): " TUNNEL_PORT
    TUNNEL_PORT=${TUNNEL_PORT:-20000}

    if command -v ufw &>/dev/null; then
        ufw allow ${TUNNEL_PORT}/tcp && print_ok "ufw: پورت $TUNNEL_PORT باز شد"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port=${TUNNEL_PORT}/tcp
        firewall-cmd --reload && print_ok "firewalld: پورت $TUNNEL_PORT باز شد"
    else
        iptables -A INPUT -p tcp --dport ${TUNNEL_PORT} -j ACCEPT
        print_ok "iptables: پورت $TUNNEL_PORT باز شد"
    fi

    print_ok "سرور آماده‌ست! منتظر اتصال از ایران باش."
}

# ────────────────────────────────────────────────
setup_client() {
    print_step "تنظیم کلاینت ایران..."

    echo ""
    read -p "آیا از پروکسی (SOCKS5) استفاده می‌کنی؟ [y/N]: " USE_PROXY
    PROXY_CMD=""
    if [[ "$USE_PROXY" =~ ^[Yy]$ ]]; then
        read -p "آدرس پروکسی (مثال 188.121.124.130:27110): " PROXY_ADDR
        [[ -z "$PROXY_ADDR" ]] && { print_err "آدرس پروکسی وارد نشد"; exit 1; }
        PROXY_CMD="-o \"ProxyCommand=nc -x $PROXY_ADDR -X 5 %h %p\""
        print_ok "پروکسی: $PROXY_ADDR"
    fi

    read -p "آدرس سرور خارج: " REMOTE_HOST
    [[ -z "$REMOTE_HOST" ]] && { print_err "آدرس سرور وارد نشد"; exit 1; }

    read -p "یوزر SSH سرور خارج (پیش‌فرض root): " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    read -p "پورت SSH سرور خارج (پیش‌فرض 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    read -p "پورت تانل (پیش‌فرض 20000): " TUNNEL_PORT
    TUNNEL_PORT=${TUNNEL_PORT:-20000}

    read -p "پورت لوکال (پیش‌فرض $TUNNEL_PORT): " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}

    # Generate SSH key if needed
    if [[ ! -f ~/.ssh/id_rsa ]]; then
        print_step "کلید SSH ساخته می‌شه..."
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
        print_ok "کلید SSH ساخته شد"
    fi

    # Copy SSH key to remote
    echo ""
    print_step "ارسال کلید SSH به سرور خارج..."
    if [[ -n "$PROXY_CMD" ]]; then
        eval ssh-copy-id $PROXY_CMD -p $SSH_PORT ${REMOTE_USER}@${REMOTE_HOST}
    else
        ssh-copy-id -p $SSH_PORT ${REMOTE_USER}@${REMOTE_HOST}
    fi

    # Write tunnel script
    TUNNEL_SCRIPT="/usr/local/bin/ssh-tunnel"
    cat > $TUNNEL_SCRIPT << EOF
#!/bin/bash
PROXY_CMD="${PROXY_CMD}"
REMOTE_HOST="${REMOTE_HOST}"
REMOTE_USER="${REMOTE_USER}"
SSH_PORT="${SSH_PORT}"
TUNNEL_PORT="${TUNNEL_PORT}"
LOCAL_PORT="${LOCAL_PORT}"

while true; do
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - در حال اتصال به \${REMOTE_HOST}..."
    ssh \\
        \${PROXY_CMD} \\
        -p \${SSH_PORT} \\
        -o "ServerAliveInterval=30" \\
        -o "ServerAliveCountMax=3" \\
        -o "ExitOnForwardFailure=yes" \\
        -o "StrictHostKeyChecking=no" \\
        -o "ConnectTimeout=15" \\
        -N \\
        -R 0.0.0.0:\${TUNNEL_PORT}:127.0.0.1:\${LOCAL_PORT} \\
        \${REMOTE_USER}@\${REMOTE_HOST}

    echo "\$(date '+%Y-%m-%d %H:%M:%S') - قطع شد! تلاش مجدد در 5 ثانیه..."
    sleep 5
done
EOF
    chmod +x $TUNNEL_SCRIPT
    print_ok "اسکریپت تانل: $TUNNEL_SCRIPT"

    # Systemd service
    cat > /etc/systemd/system/ssh-tunnel.service << EOF
[Unit]
Description=SSH Reverse Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssh-tunnel
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ssh-tunnel
    systemctl start ssh-tunnel

    print_ok "سرویس نصب و فعال شد"
    echo ""
    echo -e "${GREEN}${BOLD}══════════════════════════════════════${NC}"
    print_ok "تانل فعاله! بررسی وضعیت:"
    echo "  systemctl status ssh-tunnel"
    echo "  journalctl -u ssh-tunnel -f"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════${NC}"
}

# ────────────────────────────────────────────────
main() {
    [[ $EUID -ne 0 ]] && { print_err "با root اجرا کن: sudo bash setup.sh"; exit 1; }
    print_banner
    ask_mode
    [[ "$MODE" == "2" ]] && setup_server || setup_client
}

main
