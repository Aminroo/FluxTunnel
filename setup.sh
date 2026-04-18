#!/bin/bash

# =====================================================
#   SSH Reverse Tunnel Manager v2.0
#   github.com/your-repo
#   Usage: sudo bash setup.sh
# =====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

CONFIG_DIR="/etc/ssh-tunnel"
TUNNELS_FILE="$CONFIG_DIR/tunnels.conf"
TUNNEL_SCRIPT="/usr/local/bin/ssh-tunnel"
SERVICE_FILE="/etc/systemd/system/ssh-tunnel.service"

# ─────────────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────────────

banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║     SSH Reverse Tunnel Manager  v2.0         ║"
    echo "  ║     Supports: Iran → Abroad (SOCKS5 proxy)   ║"
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
    [[ $EUID -ne 0 ]] && { err "Run as root:  sudo bash setup.sh"; exit 1; }
}

ensure_config_dir() {
    mkdir -p "$CONFIG_DIR"
    touch "$TUNNELS_FILE"
}

install_deps() {
    step "Checking dependencies..."
    local pkgs=()
    command -v nc      &>/dev/null || pkgs+=(netcat-openbsd)
    command -v autossh &>/dev/null || pkgs+=(autossh)
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        step "Installing: ${pkgs[*]}"
        apt-get install -y "${pkgs[@]}" -q 2>/dev/null \
        || yum install -y "${pkgs[@]}" -q 2>/dev/null \
        || warn "Could not auto-install: ${pkgs[*]} — install manually if needed"
    fi
    ok "Dependencies OK"
}

# ─────────────────────────────────────────────────────
#  SERVER SETUP  (Abroad / VPS side)
# ─────────────────────────────────────────────────────

setup_server() {
    banner
    echo -e "${BOLD}  ► SERVER SETUP  (Abroad / VPS)${NC}"
    hr

    step "Configuring sshd_config..."
    local SSHD="/etc/ssh/sshd_config"

    set_sshd() {
        local key="$1" val="$2"
        grep -q "^${key}" "$SSHD" \
            && sed -i "s/^${key}.*/${key} ${val}/" "$SSHD" \
            || echo "${key} ${val}" >> "$SSHD"
    }

    set_sshd "GatewayPorts"      "yes"
    set_sshd "AllowTcpForwarding" "yes"
    set_sshd "ClientAliveInterval" "30"
    set_sshd "ClientAliveCountMax" "6"
    systemctl restart sshd && ok "sshd restarted with GatewayPorts=yes"

    echo ""
    echo -e "  How many tunnel ports do you need? ${DIM}(1–20, default 1)${NC}"
    read -rp "  Count: " PORT_COUNT
    PORT_COUNT=${PORT_COUNT:-1}
    [[ ! "$PORT_COUNT" =~ ^[0-9]+$ || "$PORT_COUNT" -lt 1 || "$PORT_COUNT" -gt 20 ]] \
        && { err "Invalid count"; exit 1; }

    local PORTS=()
    for (( i=1; i<=PORT_COUNT; i++ )); do
        local default_port=$(( 20000 + i - 1 ))
        read -rp "  Tunnel port #${i} [default ${default_port}]: " p
        p=${p:-$default_port}
        [[ ! "$p" =~ ^[0-9]+$ || "$p" -lt 1024 || "$p" -gt 65535 ]] \
            && { err "Invalid port: $p"; exit 1; }
        PORTS+=("$p")
    done

    step "Opening firewall ports: ${PORTS[*]}"
    for p in "${PORTS[@]}"; do
        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            ufw allow "${p}/tcp" &>/dev/null && ok "ufw: opened $p/tcp"
        elif command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-port="${p}/tcp" &>/dev/null
            firewall-cmd --reload &>/dev/null && ok "firewalld: opened $p/tcp"
        else
            iptables -A INPUT -p tcp --dport "$p" -j ACCEPT && ok "iptables: opened $p/tcp"
        fi
    done

    hr
    ok "Server is ready!"
    echo ""
    info "Ports listening for incoming tunnels: ${PORTS[*]}"
    info "Run the CLIENT setup on your Iran server now."
    echo ""
}

# ─────────────────────────────────────────────────────
#  CLIENT SETUP  (Iran side)
# ─────────────────────────────────────────────────────

ask_proxy() {
    echo ""
    echo -e "  ${BOLD}Proxy Configuration${NC}"
    echo -e "  Do you need a SOCKS5 proxy to reach the abroad server?"
    echo -e "  ${DIM}(Required if your Iran server has restricted outbound)${NC}"
    echo ""
    echo "    1) Yes — use a SOCKS5 proxy"
    echo "    2) No  — direct connection"
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
        ok "SOCKS5 proxy: $PROXY_ADDR"
    fi
}

build_tunnel_entry() {
    # Args: REMOTE_USER REMOTE_HOST SSH_PORT TUNNEL_PORT LOCAL_PORT PROXY_CMD
    local REMOTE_USER="$1"
    local REMOTE_HOST="$2"
    local SSH_PORT="$3"
    local TUNNEL_PORT="$4"
    local LOCAL_PORT="$5"
    local PROXY_CMD="$6"

    local ID
    ID="${REMOTE_HOST}:${TUNNEL_PORT}"
    echo "${ID}|${REMOTE_USER}|${REMOTE_HOST}|${SSH_PORT}|${TUNNEL_PORT}|${LOCAL_PORT}|${PROXY_CMD}"
}

wait_for_connection() {
    local REMOTE_HOST="$1"
    local SSH_PORT="$2"
    local PROXY_CMD="$3"
    local MAX_WAIT=60
    local elapsed=0

    step "Waiting for successful SSH connection to $REMOTE_HOST:$SSH_PORT ..."
    echo -e "  ${DIM}(timeout ${MAX_WAIT}s)${NC}"

    while [[ $elapsed -lt $MAX_WAIT ]]; do
        if [[ -n "$PROXY_CMD" ]]; then
            ssh -o "$PROXY_CMD" \
                -o "StrictHostKeyChecking=no" \
                -o "ConnectTimeout=5" \
                -o "BatchMode=yes" \
                -p "$SSH_PORT" \
                "root@${REMOTE_HOST}" "exit" 2>/dev/null
        else
            ssh -o "StrictHostKeyChecking=no" \
                -o "ConnectTimeout=5" \
                -o "BatchMode=yes" \
                -p "$SSH_PORT" \
                "root@${REMOTE_HOST}" "exit" 2>/dev/null
        fi

        if [[ $? -eq 0 ]]; then
            ok "Connection to $REMOTE_HOST established!"
            return 0
        fi

        printf "  Attempt %d/%d...\r" "$((elapsed+1))" "$MAX_WAIT"
        sleep 1
        (( elapsed++ ))
    done

    echo ""
    err "Could not connect to $REMOTE_HOST:$SSH_PORT within ${MAX_WAIT}s"
    return 1
}

generate_tunnel_script() {
    step "Generating tunnel runner script..."

    cat > "$TUNNEL_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# Auto-generated by SSH Tunnel Manager v2.0
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

# Launch each tunnel in background
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    run_tunnel "$line" &
done < "$TUNNELS_FILE"

log "All tunnels launched ($(wc -l < "$TUNNELS_FILE") entries)"
wait
SCRIPT_EOF

    chmod +x "$TUNNEL_SCRIPT"
    ok "Tunnel script: $TUNNEL_SCRIPT"
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
    ok "Service installed & enabled (ssh-tunnel)"
}

setup_client() {
    banner
    echo -e "${BOLD}  ► CLIENT SETUP  (Iran / restricted server)${NC}"
    hr

    ensure_config_dir
    install_deps

    ask_proxy

    echo ""
    echo -e "  ${BOLD}Remote Server (Abroad / VPS)${NC}"
    read -rp "  SSH host (IP or domain): " REMOTE_HOST
    [[ -z "$REMOTE_HOST" ]] && { err "Host required"; exit 1; }

    read -rp "  SSH user [default root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    read -rp "  SSH port [default 22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    echo ""
    echo -e "  ${BOLD}Tunnel Ports${NC}"
    echo -e "  How many tunnels to create? ${DIM}(1–20, default 1)${NC}"
    read -rp "  Count: " TUNNEL_COUNT
    TUNNEL_COUNT=${TUNNEL_COUNT:-1}
    [[ ! "$TUNNEL_COUNT" =~ ^[0-9]+$ || "$TUNNEL_COUNT" -lt 1 || "$TUNNEL_COUNT" -gt 20 ]] \
        && { err "Invalid count"; exit 1; }

    local ENTRIES=()
    for (( i=1; i<=TUNNEL_COUNT; i++ )); do
        echo ""
        echo -e "  ${CYAN}── Tunnel #${i} ──${NC}"
        local default_t=$(( 20000 + i - 1 ))
        read -rp "  Remote tunnel port [default ${default_t}]: " TUNNEL_PORT
        TUNNEL_PORT=${TUNNEL_PORT:-$default_t}

        read -rp "  Local port to forward [default ${TUNNEL_PORT}]: " LOCAL_PORT
        LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}

        ENTRIES+=("$(build_tunnel_entry "$REMOTE_USER" "$REMOTE_HOST" "$SSH_PORT" "$TUNNEL_PORT" "$LOCAL_PORT" "$PROXY_CMD")")
        ok "Tunnel #${i}: local:${LOCAL_PORT} → ${REMOTE_HOST}:${TUNNEL_PORT}"
    done

    # SSH key
    if [[ ! -f ~/.ssh/id_rsa ]]; then
        step "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa -q
        ok "SSH key created: ~/.ssh/id_rsa"
    else
        ok "SSH key found: ~/.ssh/id_rsa"
    fi

    # Copy key
    step "Copying SSH key to remote server..."
    echo -e "  ${DIM}(You may be asked for the remote password)${NC}"
    if [[ -n "$PROXY_CMD" ]]; then
        ssh-copy-id -o "$PROXY_CMD" -o "StrictHostKeyChecking=no" -p "$SSH_PORT" "${REMOTE_USER}@${REMOTE_HOST}"
    else
        ssh-copy-id -o "StrictHostKeyChecking=no" -p "$SSH_PORT" "${REMOTE_USER}@${REMOTE_HOST}"
    fi

    if [[ $? -ne 0 ]]; then
        warn "ssh-copy-id failed — you may need to add the key manually"
        warn "Public key: $(cat ~/.ssh/id_rsa.pub)"
        read -rp "  Press Enter once key is added to remote authorized_keys, or Ctrl+C to abort..."
    else
        ok "SSH key installed on remote"
    fi

    # Wait for successful connection before writing config
    wait_for_connection "$REMOTE_HOST" "$SSH_PORT" "$PROXY_CMD"
    if [[ $? -ne 0 ]]; then
        err "Aborting setup — connection not established"
        exit 1
    fi

    # Write tunnels config
    step "Writing tunnel configuration..."
    for entry in "${ENTRIES[@]}"; do
        echo "$entry" >> "$TUNNELS_FILE"
    done
    ok "Config saved: $TUNNELS_FILE"

    generate_tunnel_script
    generate_service

    systemctl restart ssh-tunnel
    sleep 2

    if systemctl is-active ssh-tunnel &>/dev/null; then
        ok "ssh-tunnel service is RUNNING"
    else
        warn "Service may have issues — check: journalctl -u ssh-tunnel -f"
    fi

    hr
    echo ""
    echo -e "${GREEN}${BOLD}  ✓ Setup complete! All ${TUNNEL_COUNT} tunnel(s) are active.${NC}"
    echo ""
    info "Status:   systemctl status ssh-tunnel"
    info "Logs:     journalctl -u ssh-tunnel -f"
    info "Manage:   sudo bash setup.sh  → Admin Panel"
    echo ""
}

# ─────────────────────────────────────────────────────
#  ADMIN PANEL
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
    printf "  %-4s %-20s %-8s %-14s %-12s %-12s %s\n" \
        "#" "Remote Host" "SSH Port" "Tunnel Port" "Local Port" "Proxy" "Status"
    hr

    while IFS='|' read -r ID REMOTE_USER REMOTE_HOST SSH_PORT TUNNEL_PORT LOCAL_PORT PROXY_CMD; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        local proxy_label="none"
        [[ -n "$PROXY_CMD" ]] && proxy_label="socks5"

        # Check if this tunnel is running
        local status="${RED}down${NC}"
        if systemctl is-active ssh-tunnel &>/dev/null; then
            status="${GREEN}up${NC}"
        fi

        printf "  %-4s %-20s %-8s %-14s %-12s %-12s " \
            "$i" "$REMOTE_HOST" "$SSH_PORT" "$TUNNEL_PORT" "$LOCAL_PORT" "$proxy_label"
        echo -e "${status}"
        (( i++ ))
    done < "$TUNNELS_FILE"
    echo ""
    return 0
}

delete_tunnel() {
    list_tunnels || return
    read -rp "  Enter tunnel # to delete (or 0 to cancel): " DEL_NUM
    [[ "$DEL_NUM" == "0" || -z "$DEL_NUM" ]] && return

    local i=1
    local NEW_CONF=""
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
    read -rp "  Enter tunnel # to edit (or 0 to cancel): " EDIT_NUM
    [[ "$EDIT_NUM" == "0" || -z "$EDIT_NUM" ]] && return

    local i=1
    local FOUND=0
    local NEW_CONF=""

    while IFS='|' read -r ID REMOTE_USER REMOTE_HOST SSH_PORT TUNNEL_PORT LOCAL_PORT PROXY_CMD; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        if [[ "$i" -eq "$EDIT_NUM" ]]; then
            FOUND=1
            echo ""
            echo -e "  ${BOLD}Editing Tunnel #${EDIT_NUM}${NC}  (press Enter to keep current value)"
            echo ""

            read -rp "  Remote host [${REMOTE_HOST}]: " NEW_HOST
            NEW_HOST=${NEW_HOST:-$REMOTE_HOST}

            read -rp "  Remote user [${REMOTE_USER}]: " NEW_USER
            NEW_USER=${NEW_USER:-$REMOTE_USER}

            read -rp "  SSH port [${SSH_PORT}]: " NEW_SSH_PORT
            NEW_SSH_PORT=${NEW_SSH_PORT:-$SSH_PORT}

            read -rp "  Tunnel port [${TUNNEL_PORT}]: " NEW_TUNNEL_PORT
            NEW_TUNNEL_PORT=${NEW_TUNNEL_PORT:-$TUNNEL_PORT}

            read -rp "  Local port [${LOCAL_PORT}]: " NEW_LOCAL_PORT
            NEW_LOCAL_PORT=${NEW_LOCAL_PORT:-$LOCAL_PORT}

            echo ""
            local current_proxy="none"
            [[ -n "$PROXY_CMD" ]] && current_proxy="$PROXY_CMD"
            echo "  Current proxy: ${current_proxy}"
            read -rp "  New SOCKS5 proxy (host:port), 'none' to clear, Enter to keep: " NEW_PROXY_RAW
            local NEW_PROXY_CMD="$PROXY_CMD"
            if [[ "$NEW_PROXY_RAW" == "none" ]]; then
                NEW_PROXY_CMD=""
            elif [[ -n "$NEW_PROXY_RAW" ]]; then
                local ph="${NEW_PROXY_RAW%:*}"
                local pp="${NEW_PROXY_RAW##*:}"
                NEW_PROXY_CMD="ProxyCommand=nc -x ${ph}:${pp} -X 5 %h %p"
            fi

            local NEW_ID="${NEW_HOST}:${NEW_TUNNEL_PORT}"
            NEW_CONF+="${NEW_ID}|${NEW_USER}|${NEW_HOST}|${NEW_SSH_PORT}|${NEW_TUNNEL_PORT}|${NEW_LOCAL_PORT}|${NEW_PROXY_CMD}\n"
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

add_tunnel_interactive() {
    banner
    echo -e "${BOLD}  ► ADD TUNNEL${NC}"
    hr

    ask_proxy

    read -rp "  Remote host (IP or domain): " REMOTE_HOST
    [[ -z "$REMOTE_HOST" ]] && { err "Host required"; return; }

    read -rp "  SSH user [default root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}

    read -rp "  SSH port [default 22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    read -rp "  Tunnel port on remote [default 20000]: " TUNNEL_PORT
    TUNNEL_PORT=${TUNNEL_PORT:-20000}

    read -rp "  Local port to forward [default ${TUNNEL_PORT}]: " LOCAL_PORT
    LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}

    local ENTRY
    ENTRY="$(build_tunnel_entry "$REMOTE_USER" "$REMOTE_HOST" "$SSH_PORT" "$TUNNEL_PORT" "$LOCAL_PORT" "$PROXY_CMD")"
    echo "$ENTRY" >> "$TUNNELS_FILE"

    generate_tunnel_script
    systemctl restart ssh-tunnel && ok "Tunnel added & service restarted"
}

admin_panel() {
    while true; do
        banner
        echo -e "${BOLD}  ► ADMIN PANEL${NC}"
        hr
        echo ""

        # Service status
        if systemctl is-active ssh-tunnel &>/dev/null; then
            echo -e "  Service Status: ${GREEN}${BOLD}RUNNING${NC}"
        else
            echo -e "  Service Status: ${RED}${BOLD}STOPPED${NC}"
        fi
        echo ""
        echo "  1) List tunnels"
        echo "  2) Add tunnel"
        echo "  3) Edit tunnel"
        echo "  4) Delete tunnel"
        echo "  5) Restart service"
        echo "  6) Stop service"
        echo "  7) Start service"
        echo "  8) View live logs"
        echo "  9) View log file"
        echo "  0) Exit"
        echo ""
        hr
        read -rp "  Choice: " CHOICE

        case "$CHOICE" in
            1) list_tunnels; read -rp "  [Enter to continue]" ;;
            2) add_tunnel_interactive ;;
            3) edit_tunnel ;;
            4) delete_tunnel ;;
            5)
                systemctl restart ssh-tunnel && ok "Service restarted"
                sleep 1
                ;;
            6)
                systemctl stop ssh-tunnel && ok "Service stopped"
                sleep 1
                ;;
            7)
                systemctl start ssh-tunnel && ok "Service started"
                sleep 1
                ;;
            8)
                echo -e "${DIM}  Press Ctrl+C to exit logs${NC}"
                journalctl -u ssh-tunnel -f
                ;;
            9)
                local LOG="$CONFIG_DIR/tunnel.log"
                if [[ -f "$LOG" ]]; then
                    tail -50 "$LOG" | less -R
                else
                    warn "No log file found at $LOG"
                    sleep 1
                fi
                ;;
            0) echo ""; exit 0 ;;
            *) warn "Invalid choice" ; sleep 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────
#  MAIN MENU
# ─────────────────────────────────────────────────────

main() {
    require_root
    banner

    # If tunnels already exist, go to admin panel directly
    if [[ -f "$TUNNELS_FILE" && -s "$TUNNELS_FILE" ]]; then
        echo -e "  ${BOLD}Existing installation detected.${NC}"
        echo ""
        echo "  1) Admin Panel  (manage tunnels)"
        echo "  2) Add new server setup  (Iran client)"
        echo "  3) Server setup  (Abroad VPS)"
        echo "  0) Exit"
        echo ""
        read -rp "  Choice: " INIT_CHOICE
        case "$INIT_CHOICE" in
            1) admin_panel ;;
            2) setup_client ;;
            3) setup_server ;;
            0) exit 0 ;;
            *) admin_panel ;;
        esac
        return
    fi

    echo -e "  ${BOLD}Which server is this?${NC}"
    echo ""
    echo "  1) Iran server       (client — creates tunnel outward)"
    echo "  2) Abroad / VPS      (server — receives tunnel)"
    echo "  3) Admin Panel       (manage existing tunnels)"
    echo "  0) Exit"
    echo ""
    read -rp "  Choice: " MODE

    case "$MODE" in
        1) setup_client ;;
        2) setup_server ;;
        3) ensure_config_dir; admin_panel ;;
        0) exit 0 ;;
        *) err "Invalid choice"; exit 1 ;;
    esac
}

main
