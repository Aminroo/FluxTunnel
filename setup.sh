#!/bin/bash

# =====================================================
#   SSH Reverse Tunnel Manager v2.1
#   github.com/your-repo
#   Usage: sudo bash setup.sh
# =====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

CONFIG_DIR="/etc/ssh-tunnel"
TUNNELS_FILE="$CONFIG_DIR/tunnels.conf"
TUNNEL_SCRIPT="/usr/local/bin/ssh-tunnel"
SERVICE_FILE="/etc/systemd/system/ssh-tunnel.service"

# ─────────────────────────────────────────────────────
#  Print helpers
# ─────────────────────────────────────────────────────

banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║     SSH Reverse Tunnel Manager  v2.1         ║"
    echo "  ║     Eran  →  Kharej  (SOCKS5 proxy support)  ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

step()  { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
info()  { echo -e "${DIM}    $1${NC}"; }
hr()    { echo -e "${CYAN}${BOLD}──────────────────────────────────────────────${NC}"; }

require_root() {
    [[ $EUID -ne 0 ]] && { err "Run as root: sudo bash setup.sh"; exit 1; }
}

ensure_config_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$TUNNELS_FILE"
}

install_deps() {
    step "Checking dependencies..."
    local pkgs=()
    command -v nc      &>/dev/null || pkgs+=(netcat-openbsd)
    command -v sshpass &>/dev/null || pkgs+=(sshpass)

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        step "Installing: ${pkgs[*]}"
        apt-get install -y "${pkgs[@]}" -q 2>/dev/null \
        || yum install -y "${pkgs[@]}" -q 2>/dev/null \
        || warn "Could not auto-install: ${pkgs[*]} — install manually"
    fi
    ok "Dependencies OK"
}

# ─────────────────────────────────────────────────────
#  SERVER SETUP  (Kharej / VPS side)
# ─────────────────────────────────────────────────────

setup_server() {
    banner
    echo -e "${BOLD}  ► Server Setup  (Kharej / VPS)${NC}"
    hr

    step "Configuring sshd..."
    local SSHD="/etc/ssh/sshd_config"

    set_sshd() {
        local key="$1" val="$2"
        grep -q "^${key}" "$SSHD" \
            && sed -i "s/^${key}.*/${key} ${val}/" "$SSHD" \
            || echo "${key} ${val}" >> "$SSHD"
    }

    set_sshd "GatewayPorts"       "yes"
    set_sshd "AllowTcpForwarding"  "yes"
    set_sshd "ClientAliveInterval" "30"
    set_sshd "ClientAliveCountMax" "6"
    systemctl restart sshd && ok "sshd restarted — GatewayPorts=yes active"

    echo ""
    # Finglish prompt
    echo -e "  Chand ta tunnel port mikhai baz koni? ${DIM}(1–20, default 1)${NC}"
    read -rp "  Tedad: " PORT_COUNT
    PORT_COUNT=${PORT_COUNT:-1}
    [[ ! "$PORT_COUNT" =~ ^[0-9]+$ || "$PORT_COUNT" -lt 1 || "$PORT_COUNT" -gt 20 ]] \
        && { err "Invalid number"; exit 1; }

    local PORTS=()
    for (( i=1; i<=PORT_COUNT; i++ )); do
        local default_port=$(( 20000 + i - 1 ))
        read -rp "  Port #${i} [default ${default_port}]: " p
        p=${p:-$default_port}
        [[ ! "$p" =~ ^[0-9]+$ || "$p" -lt 1024 || "$p" -gt 65535 ]] \
            && { err "Invalid port: $p"; exit 1; }
        PORTS+=("$p")
    done

    step "Opening firewall ports: ${PORTS[*]}"
    for p in "${PORTS[@]}"; do
        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            ufw allow "${p}/tcp" &>/dev/null && ok "ufw: port $p/tcp opened"
        elif command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-port="${p}/tcp" &>/dev/null
            firewall-cmd --reload &>/dev/null && ok "firewalld: port $p/tcp opened"
        else
            iptables -A INPUT -p tcp --dport "$p" -j ACCEPT && ok "iptables: port $p/tcp opened"
        fi
    done

    hr
    ok "Server ready!"
    echo ""
    info "Tunnel ports: ${PORTS[*]}"
    # Finglish tip
    info "Hala ro server Eran, setup.sh ro ejra kon."
    echo ""
}

# ─────────────────────────────────────────────────────
#  CLIENT SETUP  (Eran side)
# ─────────────────────────────────────────────────────

ask_proxy() {
    echo ""
    echo -e "  ${BOLD}Proxy Configuration${NC}"
    # Finglish question
    echo -e "  Proxy SOCKS5 dari baraye vasl shodan be server kharej?"
    echo -e "  ${DIM}(If outbound is restricted on your Iran server)${NC}"
    echo ""
    echo "    1) Dare  — SOCKS5 proxy daram"
    echo "    2) Nist  — direct connect"
    echo ""
    read -rp "  Choice [1/2, default 2]: " PROXY_CHOICE
    PROXY_CHOICE=${PROXY_CHOICE:-2}

    PROXY_CMD=""
    PROXY_ADDR=""

    if [[ "$PROXY_CHOICE" == "1" ]]; then
        echo ""
        read -rp "  SOCKS5 proxy address (e.g. 188.121.124.130:1080): " PROXY_ADDR
        [[ -z "$PROXY_ADDR" ]] && { err "Proxy address required"; exit 1; }

        local proxy_host proxy_port
        proxy_host="${PROXY_ADDR%:*}"
        proxy_port="${PROXY_ADDR##*:}"
        [[ -z "$proxy_host" || -z "$proxy_port" ]] && { err "Format: host:port"; exit 1; }

        PROXY_CMD="ProxyCommand=nc -x ${proxy_host}:${proxy_port} -X 5 %h %p"
        ok "SOCKS5 proxy set: $PROXY_ADDR"
    fi
}

ask_auth() {
    echo ""
    echo -e "  ${BOLD}Authentication${NC}"
    # Finglish
    echo -e "  Roosh vasl shodan be server kharej:"
    echo ""
    echo "    1) Ba ramz (password)  — script khodesh key copy mikone"
    echo "    2) Key daram           — no password needed"
    echo ""
    read -rp "  Choice [1/2, default 1]: " AUTH_CHOICE
    AUTH_CHOICE=${AUTH_CHOICE:-1}

    REMOTE_PASS=""
    if [[ "$AUTH_CHOICE" == "1" ]]; then
        echo ""
        read -rsp "  Ramz SSH server kharej: " REMOTE_PASS
        echo ""
        [[ -z "$REMOTE_PASS" ]] && { err "Password required"; exit 1; }
        ok "Password received"
    else
        ok "Key-based mode — no password needed"
    fi
}

build_tunnel_entry() {
    local REMOTE_USER="$1"
    local REMOTE_HOST="$2"
    local SSH_PORT="$3"
    local TUNNEL_PORT="$4"
    local LOCAL_PORT="$5"
    local PROXY_CMD="$6"

    local ID="${REMOTE_HOST}:${TUNNEL_PORT}"
    echo "${ID}|${REMOTE_USER}|${REMOTE_HOST}|${SSH_PORT}|${TUNNEL_PORT}|${LOCAL_PORT}|${PROXY_CMD}"
}

copy_ssh_key() {
    local REMOTE_USER="$1"
    local REMOTE_HOST="$2"
    local SSH_PORT="$3"
    local PROXY_CMD="$4"
    local REMOTE_PASS="$5"

    if [[ ! -f ~/.ssh/id_rsa ]]; then
        step "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa -q
        ok "SSH key created: ~/.ssh/id_rsa"
    else
        ok "SSH key found: ~/.ssh/id_rsa"
    fi

    step "Copying SSH key to remote server..."
    local COPY_ARGS=()
    [[ -n "$PROXY_CMD" ]] && COPY_ARGS+=(-o "$PROXY_CMD")
    COPY_ARGS+=(-o "StrictHostKeyChecking=no" -p "$SSH_PORT")

    if [[ -n "$REMOTE_PASS" ]]; then
        SSHPASS="$REMOTE_PASS" sshpass -e ssh-copy-id "${COPY_ARGS[@]}" "${REMOTE_USER}@${REMOTE_HOST}"
    else
        ssh-copy-id "${COPY_ARGS[@]}" "${REMOTE_USER}@${REMOTE_HOST}"
    fi

    if [[ $? -eq 0 ]]; then
        ok "SSH key installed — passwordless from now on"
    else
        warn "ssh-copy-id failed — add this key manually to remote authorized_keys:"
        echo ""
        echo -e "  ${YELLOW}$(cat ~/.ssh/id_rsa.pub)${NC}"
        echo ""
        # Finglish
        read -rp "  Ba ezafe kardan key Enter bezan, ya Ctrl+C baraye cancel: "
    fi
}

wait_for_connection() {
    local REMOTE_HOST="$1"
    local SSH_PORT="$2"
    local PROXY_CMD="$3"
    local REMOTE_USER="$4"
    local MAX_WAIT=60
    local elapsed=0

    step "Waiting for successful connection to ${REMOTE_HOST}:${SSH_PORT}..."
    echo -e "  ${DIM}(timeout ${MAX_WAIT}s)${NC}"

    while [[ $elapsed -lt $MAX_WAIT ]]; do
        local ssh_test_args=()
        [[ -n "$PROXY_CMD" ]] && ssh_test_args+=(-o "$PROXY_CMD")
        ssh_test_args+=(
            -o "StrictHostKeyChecking=no"
            -o "ConnectTimeout=5"
            -o "BatchMode=yes"
            -p "$SSH_PORT"
        )

        ssh "${ssh_test_args[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "exit" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo ""
            ok "Connection established to ${REMOTE_HOST}!"
            return 0
        fi

        printf "  Attempt %d/%d...  \r" "$((elapsed+1))" "$MAX_WAIT"
        sleep 1
        (( elapsed++ ))
    done

    echo ""
    err "Could not connect to ${REMOTE_HOST}:${SSH_PORT} within ${MAX_WAIT}s"
    return 1
}

generate_tunnel_script() {
    step "Generating tunnel runner script..."

    cat > "$TUNNEL_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# Auto-generated by SSH Tunnel Manager v2.1
CONFIG_DIR="/etc/ssh-tunnel"
TUNNELS_FILE="$CONFIG_DIR/tunnels.conf"
LOG_FILE="$CONFIG_DIR/tunnel.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }

run_tunnel() {
    local LINE="$1"
    IFS='|' read -r ID REMOTE_USER REMOTE_HOST SSH_PORT TUNNEL_PORT LOCAL_PORT PROXY_CMD <<< "$LINE"

    local SSH_OPTS=(
        -N
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=3"
        -o "ExitOnForwardFailure=yes"
        -o "StrictHostKeyChecking=no"
        -o "ConnectTimeout=15"
        -o "TCPKeepAlive=yes"
        -p "$SSH_PORT"
        -R "0.0.0.0:${TUNNEL_PORT}:127.0.0.1:${LOCAL_PORT}"
    )

    [[ -n "$PROXY_CMD" ]] && SSH_OPTS+=(-o "$PROXY_CMD")

    while true; do
        log "[TUNNEL $ID] Connecting to ${REMOTE_USER}@${REMOTE_HOST}..."
        ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}"
        log "[TUNNEL $ID] Disconnected. Retrying in 5s..."
        sleep 5
    done
}

while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    run_tunnel "$line" &
done < "$TUNNELS_FILE"

log "All tunnels launched."
wait
SCRIPT_EOF

    chmod +x "$TUNNEL_SCRIPT"
    ok "Tunnel runner: $TUNNEL_SCRIPT"
}

generate_service() {
    step "Installing systemd service..."
    cat > "$SERVICE_FILE" << 'SVC_EOF'
[Unit]
Description=SSH Reverse Tunnel Manager
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
SVC_EOF

    systemctl daemon-reload
    systemctl enable ssh-tunnel &>/dev/null
    ok "Service installed and enabled (ssh-tunnel)"
}

setup_client() {
    banner
    echo -e "${BOLD}  ► Client Setup  (Eran / restricted server)${NC}"
    hr

    ensure_config_dir
    install_deps

    ask_proxy

    echo ""
    echo -e "  ${BOLD}Remote Server (Kharej / VPS)${NC}"
    read -rp "  SSH host (IP or domain): " REMOTE_HOST
    [[ -z "$REMOTE_HOST" ]] && { err "Host required"; exit 1; }

    read -rp "  SSH user [default root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    read -rp "  SSH port [default 22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    ask_auth

    echo ""
    echo -e "  ${BOLD}Tunnel Ports${NC}"
    # Finglish
    echo -e "  Chand ta tunnel mikhai besazi? ${DIM}(1–20, default 1)${NC}"
    read -rp "  Tedad: " TUNNEL_COUNT
    TUNNEL_COUNT=${TUNNEL_COUNT:-1}
    [[ ! "$TUNNEL_COUNT" =~ ^[0-9]+$ || "$TUNNEL_COUNT" -lt 1 || "$TUNNEL_COUNT" -gt 20 ]] \
        && { err "Invalid number"; exit 1; }

    local ENTRIES=()
    for (( i=1; i<=TUNNEL_COUNT; i++ )); do
        echo ""
        echo -e "  ${CYAN}── Tunnel #${i} ──${NC}"
        local default_t=$(( 20000 + i - 1 ))
        # Finglish
        read -rp "  Port tunnel ro server kharej [default ${default_t}]: " TUNNEL_PORT
        TUNNEL_PORT=${TUNNEL_PORT:-$default_t}

        read -rp "  Local port ke forward mishe [default ${TUNNEL_PORT}]: " LOCAL_PORT
        LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}

        ENTRIES+=("$(build_tunnel_entry "$REMOTE_USER" "$REMOTE_HOST" "$SSH_PORT" "$TUNNEL_PORT" "$LOCAL_PORT" "$PROXY_CMD")")
        ok "Tunnel #${i}: local:${LOCAL_PORT} → ${REMOTE_HOST}:${TUNNEL_PORT}"
    done

    copy_ssh_key "$REMOTE_USER" "$REMOTE_HOST" "$SSH_PORT" "$PROXY_CMD" "$REMOTE_PASS"

    wait_for_connection "$REMOTE_HOST" "$SSH_PORT" "$PROXY_CMD" "$REMOTE_USER"
    if [[ $? -ne 0 ]]; then
        err "Connection failed — setup aborted"
        exit 1
    fi

    step "Saving tunnel config..."
    for entry in "${ENTRIES[@]}"; do
        echo "$entry" >> "$TUNNELS_FILE"
    done
    ok "Config saved: $TUNNELS_FILE"

    generate_tunnel_script
    generate_service

    systemctl restart ssh-tunnel
    sleep 2

    if systemctl is-active ssh-tunnel &>/dev/null; then
        ok "Service ssh-tunnel is running!"
    else
        warn "Service may have issues — check: journalctl -u ssh-tunnel -f"
    fi

    hr
    echo ""
    echo -e "${GREEN}${BOLD}  ✓ Setup complete! ${TUNNEL_COUNT} tunnel(s) active.${NC}"
    echo ""
    info "Status:  systemctl status ssh-tunnel"
    info "Logs:    journalctl -u ssh-tunnel -f"
    # Finglish tip
    info "Modiriat: sudo bash setup.sh → Admin Panel"
    echo ""
}

# ─────────────────────────────────────────────────────
#  ADMIN PANEL functions
# ─────────────────────────────────────────────────────

list_tunnels() {
    echo ""
    if [[ ! -s "$TUNNELS_FILE" ]]; then
        warn "No tunnels configured."
        return 1
    fi

    local i=1
    echo -e "  ${BOLD}Configured Tunnels:${NC}"
    hr
    printf "  %-4s %-22s %-10s %-13s %-12s %-10s %s\n" \
        "#" "Remote Host" "SSH Port" "Tunnel Port" "Local Port" "Proxy" "Status"
    hr

    while IFS='|' read -r ID REMOTE_USER REMOTE_HOST SSH_PORT TUNNEL_PORT LOCAL_PORT PROXY_CMD; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        local proxy_label="none"
        [[ -n "$PROXY_CMD" ]] && proxy_label="socks5"

        local status_str
        if systemctl is-active ssh-tunnel &>/dev/null; then
            status_str="${GREEN}active${NC}"
        else
            status_str="${RED}stopped${NC}"
        fi

        printf "  %-4s %-22s %-10s %-13s %-12s %-10s " \
            "$i" "$REMOTE_HOST" "$SSH_PORT" "$TUNNEL_PORT" "$LOCAL_PORT" "$proxy_label"
        echo -e "${status_str}"
        (( i++ ))
    done < "$TUNNELS_FILE"
    echo ""
    return 0
}

delete_tunnel() {
    list_tunnels || return
    # Finglish
    read -rp "  Shomare tunnel baraye hazf (0 = cancel): " DEL_NUM
    [[ "$DEL_NUM" == "0" || -z "$DEL_NUM" ]] && return

    local i=1 NEW_CONF=""
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$i" -ne "$DEL_NUM" ]]; then
            NEW_CONF+="${line}\n"
        else
            ok "Tunnel #${DEL_NUM} removed"
        fi
        (( i++ ))
    done < "$TUNNELS_FILE"

    printf "%b" "$NEW_CONF" > "$TUNNELS_FILE"
    generate_tunnel_script
    systemctl restart ssh-tunnel && ok "Service restarted"
}

edit_tunnel() {
    list_tunnels || return
    # Finglish
    read -rp "  Shomare tunnel baraye edit (0 = cancel): " EDIT_NUM
    [[ "$EDIT_NUM" == "0" || -z "$EDIT_NUM" ]] && return

    local i=1 FOUND=0 NEW_CONF=""

    while IFS='|' read -r ID REMOTE_USER REMOTE_HOST SSH_PORT TUNNEL_PORT LOCAL_PORT PROXY_CMD; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        if [[ "$i" -eq "$EDIT_NUM" ]]; then
            FOUND=1
            echo ""
            echo -e "  ${BOLD}Edit Tunnel #${EDIT_NUM}${NC}  (Enter = keep current)"
            echo ""

            read -rp "  Remote host  [${REMOTE_HOST}]: "  NEW_HOST;     NEW_HOST=${NEW_HOST:-$REMOTE_HOST}
            read -rp "  SSH user     [${REMOTE_USER}]: "  NEW_USER;     NEW_USER=${NEW_USER:-$REMOTE_USER}
            read -rp "  SSH port     [${SSH_PORT}]: "     NEW_SSH_PORT; NEW_SSH_PORT=${NEW_SSH_PORT:-$SSH_PORT}
            read -rp "  Tunnel port  [${TUNNEL_PORT}]: "  NEW_TP;       NEW_TP=${NEW_TP:-$TUNNEL_PORT}
            read -rp "  Local port   [${LOCAL_PORT}]: "   NEW_LP;       NEW_LP=${NEW_LP:-$LOCAL_PORT}

            echo ""
            local cur_proxy="none"
            [[ -n "$PROXY_CMD" ]] && cur_proxy="$PROXY_CMD"
            echo -e "  Current proxy: ${DIM}${cur_proxy}${NC}"
            read -rp "  New SOCKS5 proxy (host:port), 'none' to clear, Enter to keep: " NEW_PROXY_RAW
            local NEW_PROXY_CMD="$PROXY_CMD"
            if [[ "$NEW_PROXY_RAW" == "none" ]]; then
                NEW_PROXY_CMD=""
            elif [[ -n "$NEW_PROXY_RAW" ]]; then
                local ph="${NEW_PROXY_RAW%:*}"
                local pp="${NEW_PROXY_RAW##*:}"
                NEW_PROXY_CMD="ProxyCommand=nc -x ${ph}:${pp} -X 5 %h %p"
            fi

            local NEW_ID="${NEW_HOST}:${NEW_TP}"
            NEW_CONF+="${NEW_ID}|${NEW_USER}|${NEW_HOST}|${NEW_SSH_PORT}|${NEW_TP}|${NEW_LP}|${NEW_PROXY_CMD}\n"
            ok "Tunnel #${EDIT_NUM} updated"
        else
            NEW_CONF+="${ID}|${REMOTE_USER}|${REMOTE_HOST}|${SSH_PORT}|${TUNNEL_PORT}|${LOCAL_PORT}|${PROXY_CMD}\n"
        fi
        (( i++ ))
    done < "$TUNNELS_FILE"

    [[ $FOUND -eq 0 ]] && { err "Tunnel #${EDIT_NUM} not found"; return; }

    printf "%b" "$NEW_CONF" > "$TUNNELS_FILE"
    generate_tunnel_script
    systemctl restart ssh-tunnel && ok "Service restarted with updated config"
}

change_ports() {
    banner
    echo -e "${BOLD}  ► Change Tunnel Ports${NC}"
    hr

    list_tunnels || { read -rp "  [Enter to go back]"; return; }

    # Finglish
    read -rp "  Shomare tunnel baraye taghir port (0 = cancel): " SEL
    [[ "$SEL" == "0" || -z "$SEL" ]] && return

    local i=1 FOUND=0 NEW_CONF=""

    while IFS='|' read -r ID REMOTE_USER REMOTE_HOST SSH_PORT TUNNEL_PORT LOCAL_PORT PROXY_CMD; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        if [[ "$i" -eq "$SEL" ]]; then
            FOUND=1
            echo ""
            echo -e "  ${BOLD}Change Ports — Tunnel #${SEL}${NC}  (Enter = keep current)"
            echo ""
            read -rp "  SSH port    [current: ${SSH_PORT}]:    " NEW_SSH_PORT
            NEW_SSH_PORT=${NEW_SSH_PORT:-$SSH_PORT}
            read -rp "  Tunnel port [current: ${TUNNEL_PORT}]: " NEW_TP
            NEW_TP=${NEW_TP:-$TUNNEL_PORT}
            read -rp "  Local port  [current: ${LOCAL_PORT}]:  " NEW_LP
            NEW_LP=${NEW_LP:-$LOCAL_PORT}

            echo ""
            ok "Ports updated:"
            info "SSH port:    $SSH_PORT → $NEW_SSH_PORT"
            info "Tunnel port: $TUNNEL_PORT → $NEW_TP"
            info "Local port:  $LOCAL_PORT → $NEW_LP"

            local NEW_ID="${REMOTE_HOST}:${NEW_TP}"
            NEW_CONF+="${NEW_ID}|${REMOTE_USER}|${REMOTE_HOST}|${NEW_SSH_PORT}|${NEW_TP}|${NEW_LP}|${PROXY_CMD}\n"
        else
            NEW_CONF+="${ID}|${REMOTE_USER}|${REMOTE_HOST}|${SSH_PORT}|${TUNNEL_PORT}|${LOCAL_PORT}|${PROXY_CMD}\n"
        fi
        (( i++ ))
    done < "$TUNNELS_FILE"

    [[ $FOUND -eq 0 ]] && { err "Tunnel #${SEL} not found"; sleep 1; return; }

    printf "%b" "$NEW_CONF" > "$TUNNELS_FILE"
    generate_tunnel_script
    systemctl restart ssh-tunnel && ok "Service restarted with new ports"
    sleep 1
}

add_tunnel_interactive() {
    banner
    echo -e "${BOLD}  ► Add New Tunnel${NC}"
    hr

    ask_proxy

    read -rp "  Remote host (IP or domain): " REMOTE_HOST
    [[ -z "$REMOTE_HOST" ]] && { err "Host required"; return; }

    read -rp "  SSH user [default root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    read -rp "  SSH port [default 22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    # Finglish
    read -rp "  Port tunnel ro server kharej [default 20000]: " TUNNEL_PORT
    TUNNEL_PORT=${TUNNEL_PORT:-20000}

    read -rp "  Local port ke forward mishe [default ${TUNNEL_PORT}]: " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}

    local ENTRY
    ENTRY="$(build_tunnel_entry "$REMOTE_USER" "$REMOTE_HOST" "$SSH_PORT" "$TUNNEL_PORT" "$LOCAL_PORT" "$PROXY_CMD")"
    echo "$ENTRY" >> "$TUNNELS_FILE"

    generate_tunnel_script
    systemctl restart ssh-tunnel && ok "Tunnel added — service restarted"
}

uninstall_all() {
    banner
    echo -e "${BOLD}  ► Uninstall (Remove Everything)${NC}"
    hr
    echo ""
    warn "This will remove:"
    info "  - Service:  ssh-tunnel"
    info "  - Script:   $TUNNEL_SCRIPT"
    info "  - Config:   $CONFIG_DIR"
    info "  - Unit:     $SERVICE_FILE"
    echo ""
    # Finglish confirm
    read -rp "  Motmaeni? Benevis 'bale' baraye edame: " CONFIRM
    if [[ "$CONFIRM" != "bale" ]]; then
        warn "Cancelled."
        sleep 1
        return
    fi

    systemctl stop    ssh-tunnel 2>/dev/null; ok "Service stopped"
    systemctl disable ssh-tunnel 2>/dev/null; ok "Service disabled"
    rm -f  "$SERVICE_FILE"  && ok "Unit file removed"
    rm -f  "$TUNNEL_SCRIPT" && ok "Runner script removed"
    rm -rf "$CONFIG_DIR"    && ok "Config directory removed"
    systemctl daemon-reload

    echo ""
    ok "Uninstall complete!"
    echo ""
    exit 0
}

# ─────────────────────────────────────────────────────
#  ADMIN PANEL
# ─────────────────────────────────────────────────────

admin_panel() {
    while true; do
        banner
        echo -e "${BOLD}  ► Admin Panel${NC}"
        hr
        echo ""

        if systemctl is-active ssh-tunnel &>/dev/null; then
            echo -e "  Service Status: ${GREEN}${BOLD}RUNNING${NC}"
        else
            echo -e "  Service Status: ${RED}${BOLD}STOPPED${NC}"
        fi
        echo ""
        echo "  1)  List tunnels"
        echo "  2)  Add tunnel"
        echo "  3)  Edit tunnel"
        echo "  4)  Delete tunnel"
        echo "  5)  Change ports"
        echo "  6)  Restart service"
        echo "  7)  Stop service"
        echo "  8)  Start service"
        echo "  9)  Live logs"
        echo "  10) View log file"
        echo "  11) Uninstall"
        echo "  0)  Back"
        echo ""
        hr
        read -rp "  Choice: " CHOICE

        case "$CHOICE" in
            1)  list_tunnels; read -rp "  [Enter to continue]" ;;
            2)  add_tunnel_interactive ;;
            3)  edit_tunnel ;;
            4)  delete_tunnel ;;
            5)  change_ports ;;
            6)  systemctl restart ssh-tunnel && ok "Service restarted"; sleep 1 ;;
            7)  systemctl stop    ssh-tunnel && ok "Service stopped";   sleep 1 ;;
            8)  systemctl start   ssh-tunnel && ok "Service started";   sleep 1 ;;
            9)
                echo -e "  ${DIM}Ctrl+C to exit logs${NC}"
                journalctl -u ssh-tunnel -f
                ;;
            10)
                local LOG="$CONFIG_DIR/tunnel.log"
                if [[ -f "$LOG" ]]; then
                    tail -50 "$LOG" | less -R
                else
                    warn "Log file not found: $LOG"
                    sleep 1
                fi
                ;;
            11) uninstall_all ;;
            0)  return ;;
            *)  warn "Invalid choice"; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────
#  MAIN MENU
# ─────────────────────────────────────────────────────

main() {
    require_root

    while true; do
        banner

        if [[ -f "$TUNNELS_FILE" && -s "$TUNNELS_FILE" ]]; then
            echo -e "  ${BOLD}Main Menu${NC}"
            echo ""
            echo "  1) Admin Panel        (manage tunnels)"
            echo "  2) Client Setup       (Eran server)"
            echo "  3) Server Setup       (Kharej / VPS)"
            echo "  4) Change Ports"
            echo "  5) Uninstall"
            echo "  0) Exit"
            echo ""
            hr
            read -rp "  Choice: " CHOICE
            case "$CHOICE" in
                1) admin_panel ;;
                2) setup_client ;;
                3) setup_server ;;
                4) ensure_config_dir; change_ports ;;
                5) uninstall_all ;;
                0) echo ""; exit 0 ;;
                *) warn "Invalid choice"; sleep 1 ;;
            esac
        else
            echo -e "  ${BOLD}Main Menu${NC}"
            echo ""
            echo "  1) Client Setup   (Eran — creates tunnel outward)"
            echo "  2) Server Setup   (Kharej / VPS — receives tunnel)"
            echo "  3) Admin Panel"
            echo "  0) Exit"
            echo ""
            hr
            read -rp "  Choice: " MODE
            case "$MODE" in
                1) setup_client ;;
                2) setup_server ;;
                3) ensure_config_dir; admin_panel ;;
                0) echo ""; exit 0 ;;
                *) err "Invalid choice"; sleep 1 ;;
            esac
        fi
    done
}

main
