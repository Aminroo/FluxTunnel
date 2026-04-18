#!/bin/bash

# =====================================================
#   SSH Reverse Tunnel Manager v2.2
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
    echo "  ║     SSH Reverse Tunnel Manager  v2.2         ║"
    echo "  ║     Iran  →  VPS  (SOCKS5 proxy support)     ║"
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

# ─────────────────────────────────────────────────────
#  Ask for SOCKS5 proxy (used for installs + SSH)
# ─────────────────────────────────────────────────────

ask_proxy() {
    echo ""
    echo -e "  ${BOLD}Proxy Configuration${NC}"
    echo -e "  Do you have a SOCKS5 proxy to connect to the remote server?"
    echo -e "  ${DIM}(Required if outbound connections are restricted on this server)${NC}"
    echo ""
    echo "    1) Yes — I have a SOCKS5 proxy"
    echo "    2) No  — connect directly"
    echo ""
    read -rp "  Choice [1/2, default 2]: " PROXY_CHOICE
    PROXY_CHOICE=${PROXY_CHOICE:-2}

    PROXY_CMD=""
    PROXY_ADDR=""
    APT_PROXY_ARGS=""

    if [[ "$PROXY_CHOICE" == "1" ]]; then
        echo ""
        read -rp "  SOCKS5 proxy address (e.g. 127.0.0.1:1080): " PROXY_ADDR
        [[ -z "$PROXY_ADDR" ]] && { err "Proxy address required"; exit 1; }

        local proxy_host proxy_port
        proxy_host="${PROXY_ADDR%:*}"
        proxy_port="${PROXY_ADDR##*:}"
        [[ -z "$proxy_host" || -z "$proxy_port" ]] && { err "Format must be host:port"; exit 1; }

        PROXY_CMD="ProxyCommand=nc -x ${proxy_host}:${proxy_port} -X 5 %h %p"
        # For apt/curl installs via proxy
        APT_PROXY_ARGS="-o Acquire::http::proxy=\"socks5h://${PROXY_ADDR}\" -o Acquire::https::proxy=\"socks5h://${PROXY_ADDR}\""
        ok "SOCKS5 proxy set: $PROXY_ADDR"
    fi
}

# ─────────────────────────────────────────────────────
#  Install dependencies (proxy-aware)
# ─────────────────────────────────────────────────────

install_deps() {
    step "Checking dependencies..."
    local pkgs=()
    command -v nc      &>/dev/null || pkgs+=(netcat-openbsd)
    command -v sshpass &>/dev/null || pkgs+=(sshpass)

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        step "Installing: ${pkgs[*]}"
        if command -v apt-get &>/dev/null; then
            if [[ -n "$APT_PROXY_ARGS" ]]; then
                step "Using SOCKS5 proxy for apt..."
                eval apt-get install -y "${pkgs[@]}" -q $APT_PROXY_ARGS 2>/dev/null
            else
                apt-get install -y "${pkgs[@]}" -q 2>/dev/null
            fi
        elif command -v yum &>/dev/null; then
            if [[ -n "$PROXY_ADDR" ]]; then
                http_proxy="socks5h://${PROXY_ADDR}" yum install -y "${pkgs[@]}" -q 2>/dev/null
            else
                yum install -y "${pkgs[@]}" -q 2>/dev/null
            fi
        else
            warn "Could not auto-install: ${pkgs[*]} — please install manually"
            return
        fi

        # Verify
        local failed=()
        for pkg in "${pkgs[@]}"; do
            local bin="${pkg%%-*}"  # e.g. netcat-openbsd -> netcat, sshpass -> sshpass
            command -v "$bin" &>/dev/null || command -v nc &>/dev/null || failed+=("$pkg")
        done
        [[ ${#failed[@]} -gt 0 ]] && warn "Could not install: ${failed[*]} — install manually if needed"
    fi
    ok "Dependencies OK"
}

# ─────────────────────────────────────────────────────
#  SERVER SETUP  (VPS side)
# ─────────────────────────────────────────────────────

setup_server() {
    banner
    echo -e "${BOLD}  ► Server Setup  (VPS / Kharej)${NC}"
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
    echo -e "  How many tunnel ports do you want to open? ${DIM}(1–20, default 1)${NC}"
    read -rp "  Count: " PORT_COUNT
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
    info "Now run setup.sh on the Iran server and choose 'Client Setup'."
    echo ""
    read -rp "  [Press Enter to return to menu]"
}

# ─────────────────────────────────────────────────────
#  CLIENT SETUP  (Iran side)
# ─────────────────────────────────────────────────────

ask_auth() {
    echo ""
    echo -e "  ${BOLD}Authentication${NC}"
    echo -e "  How do you want to authenticate to the remote server?"
    echo ""
    echo "    1) Password  — script will copy the SSH key automatically"
    echo "    2) Key-based — SSH key already installed on remote server"
    echo ""
    read -rp "  Choice [1/2, default 1]: " AUTH_CHOICE
    AUTH_CHOICE=${AUTH_CHOICE:-1}

    REMOTE_PASS=""
    if [[ "$AUTH_CHOICE" == "1" ]]; then
        echo ""
        read -rsp "  SSH password for remote server: " REMOTE_PASS
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

    # Make sure sshpass is installed
    if [[ -n "$REMOTE_PASS" ]] && ! command -v sshpass &>/dev/null; then
        step "sshpass not found — attempting to install..."
        install_deps
        if ! command -v sshpass &>/dev/null; then
            err "sshpass could not be installed."
            echo ""
            warn "Please add this public key manually to the remote server's ~/.ssh/authorized_keys:"
            echo ""
            echo -e "  ${YELLOW}$(cat ~/.ssh/id_rsa.pub)${NC}"
            echo ""
            read -rp "  Press Enter after adding the key, or Ctrl+C to cancel: "
            return
        fi
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
        ok "SSH key installed — passwordless login active"
    else
        warn "ssh-copy-id failed — add this key manually to remote authorized_keys:"
        echo ""
        echo -e "  ${YELLOW}$(cat ~/.ssh/id_rsa.pub)${NC}"
        echo ""
        read -rp "  Press Enter after adding the key, or Ctrl+C to cancel: "
    fi
}

wait_for_connection() {
    local REMOTE_HOST="$1"
    local SSH_PORT="$2"
    local PROXY_CMD="$3"
    local REMOTE_USER="$4"
    local MAX_WAIT=60
    local elapsed=0

    step "Testing connection to ${REMOTE_HOST}:${SSH_PORT}..."
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
# Auto-generated by SSH Tunnel Manager v2.2
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
    echo -e "${BOLD}  ► Client Setup  (Iran / restricted server)${NC}"
    hr

    ensure_config_dir

    # Step 1: proxy first (needed for installs too)
    ask_proxy

    # Step 2: install deps using proxy if set
    install_deps

    # Step 3: remote server info
    echo ""
    echo -e "  ${BOLD}Remote Server (VPS / Kharej)${NC}"
    read -rp "  SSH host (IP or domain): " REMOTE_HOST
    [[ -z "$REMOTE_HOST" ]] && { err "Host required"; exit 1; }

    read -rp "  SSH user [default root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    read -rp "  SSH port [default 22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    # Step 4: auth
    ask_auth

    # Step 5: tunnel ports
    echo ""
    echo -e "  ${BOLD}Tunnel Configuration${NC}"
    echo -e "  How many tunnels do you want to create? ${DIM}(1–20, default 1)${NC}"
    read -rp "  Count: " TUNNEL_COUNT
    TUNNEL_COUNT=${TUNNEL_COUNT:-1}
    [[ ! "$TUNNEL_COUNT" =~ ^[0-9]+$ || "$TUNNEL_COUNT" -lt 1 || "$TUNNEL_COUNT" -gt 20 ]] \
        && { err "Invalid number"; exit 1; }

    local ENTRIES=()
    for (( i=1; i<=TUNNEL_COUNT; i++ )); do
        echo ""
        echo -e "  ${CYAN}── Tunnel #${i} ──${NC}"
        local default_t=$(( 20000 + i - 1 ))
        read -rp "  Remote tunnel port on VPS [default ${default_t}]: " TUNNEL_PORT
        TUNNEL_PORT=${TUNNEL_PORT:-$default_t}

        read -rp "  Local port to forward [default ${TUNNEL_PORT}]: " LOCAL_PORT
        LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}

        ENTRIES+=("$(build_tunnel_entry "$REMOTE_USER" "$REMOTE_HOST" "$SSH_PORT" "$TUNNEL_PORT" "$LOCAL_PORT" "$PROXY_CMD")")
        ok "Tunnel #${i}: local:${LOCAL_PORT} → ${REMOTE_HOST}:${TUNNEL_PORT}"
    done

    # Step 6: copy SSH key
    copy_ssh_key "$REMOTE_USER" "$REMOTE_HOST" "$SSH_PORT" "$PROXY_CMD" "$REMOTE_PASS"

    # Step 7: test connection
    wait_for_connection "$REMOTE_HOST" "$SSH_PORT" "$PROXY_CMD" "$REMOTE_USER"
    if [[ $? -ne 0 ]]; then
        err "Connection failed — setup aborted"
        exit 1
    fi

    # Step 8: save and start
    step "Saving tunnel config..."
    for entry in "${ENTRIES[@]}"; do
        echo "$entry" >> "$TUNNELS_FILE"
    done
    ok "Config saved: $TUNNELS_FILE"

    generate_tunnel_script
    generate_service

    systemctl restart ssh-tunnel
    sleep 2

    hr
    if systemctl is-active ssh-tunnel &>/dev/null; then
        echo ""
        echo -e "${GREEN}${BOLD}  ✓ Setup complete! ${TUNNEL_COUNT} tunnel(s) active.${NC}"
    else
        echo ""
        warn "Service may have issues — run: journalctl -u ssh-tunnel -f"
    fi
    echo ""
    info "Status:  systemctl status ssh-tunnel"
    info "Logs:    journalctl -u ssh-tunnel -f"
    echo ""
    read -rp "  [Press Enter to return to menu]"
}

# ─────────────────────────────────────────────────────
#  TUNNEL MANAGEMENT
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
    read -rp "  Tunnel number to delete (0 = cancel): " DEL_NUM
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
    read -rp "  Tunnel number to edit (0 = cancel): " EDIT_NUM
    [[ "$EDIT_NUM" == "0" || -z "$EDIT_NUM" ]] && return

    local i=1 FOUND=0 NEW_CONF=""

    while IFS='|' read -r ID REMOTE_USER REMOTE_HOST SSH_PORT TUNNEL_PORT LOCAL_PORT PROXY_CMD; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        if [[ "$i" -eq "$EDIT_NUM" ]]; then
            FOUND=1
            echo ""
            echo -e "  ${BOLD}Edit Tunnel #${EDIT_NUM}${NC}  (Enter = keep current value)"
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
    sleep 1
}

uninstall_all() {
    banner
    echo -e "${BOLD}  ► Uninstall${NC}"
    hr
    echo ""
    warn "This will remove all tunnels and service files:"
    info "  Service:  ssh-tunnel"
    info "  Script:   $TUNNEL_SCRIPT"
    info "  Config:   $CONFIG_DIR"
    info "  Unit:     $SERVICE_FILE"
    echo ""
    read -rp "  Type 'yes' to confirm uninstall: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
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
#  MAIN MENU  (single flat menu)
# ─────────────────────────────────────────────────────

main() {
    require_root
    ensure_config_dir

    while true; do
        banner

        # Service status line
        if systemctl is-active ssh-tunnel &>/dev/null 2>&1; then
            echo -e "  Service: ${GREEN}${BOLD}RUNNING${NC}"
        else
            echo -e "  Service: ${RED}${BOLD}STOPPED${NC}"
        fi
        echo ""
        hr
        echo ""
        echo "  1) Client Setup   — set up tunnel from this server to VPS"
        echo "  2) Server Setup   — configure VPS to accept tunnels"
        echo "  3) List tunnels"
        echo "  4) Edit tunnel"
        echo "  5) Delete tunnel"
        echo "  6) Restart service"
        echo "  7) View live logs"
        echo "  8) Uninstall"
        echo "  0) Exit"
        echo ""
        hr
        read -rp "  Choice: " CHOICE

        case "$CHOICE" in
            1) setup_client ;;
            2) setup_server ;;
            3) list_tunnels; read -rp "  [Press Enter to continue]" ;;
            4) edit_tunnel;  read -rp "  [Press Enter to continue]" ;;
            5) delete_tunnel; read -rp "  [Press Enter to continue]" ;;
            6) systemctl restart ssh-tunnel && ok "Service restarted"; sleep 1 ;;
            7)
                echo -e "  ${DIM}Press Ctrl+C to exit logs${NC}"
                journalctl -u ssh-tunnel -f
                ;;
            8) uninstall_all ;;
            0) echo ""; exit 0 ;;
            *) warn "Invalid choice"; sleep 1 ;;
        esac
    done
}

main
