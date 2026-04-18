#!/bin/bash

# =====================================================
#   SSH Reverse Tunnel Manager v2.3
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
    echo "  ║     SSH Reverse Tunnel Manager  v2.3         ║"
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
#  Restart sshd — handles ssh / sshd / openssh-server
# ─────────────────────────────────────────────────────

restart_sshd() {
    local svc=""
    for name in ssh sshd openssh-server; do
        if systemctl list-units --full --all 2>/dev/null | grep -q "^${name}\.service"; then
            svc="$name"
            break
        fi
    done

    if [[ -n "$svc" ]]; then
        systemctl restart "$svc" && ok "sshd restarted (service: $svc)" && return 0
    else
        systemctl restart ssh  2>/dev/null && ok "sshd restarted (ssh)"  && return 0
        systemctl restart sshd 2>/dev/null && ok "sshd restarted (sshd)" && return 0
    fi

    err "Could not restart sshd — do it manually: systemctl restart ssh"
    return 1
}

# ─────────────────────────────────────────────────────
#  Fix GatewayPorts across ALL sshd config files
# ─────────────────────────────────────────────────────

fix_gateway_ports() {
    local SSHD="/etc/ssh/sshd_config"

    step "Scanning all /etc/ssh/ files for GatewayPorts..."

    # Remove every occurrence (commented or not) from every file under /etc/ssh/
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        sed -i "/^[[:space:]]*#*[[:space:]]*GatewayPorts\b/Id" "$f"
        ok "  Cleaned: $f"
    done < <(grep -rli "GatewayPorts" /etc/ssh/ 2>/dev/null)

    # Write GatewayPorts clientspecified at the very TOP of sshd_config
    # (before any Include lines, so it wins)
    local tmp
    tmp=$(mktemp)
    echo "GatewayPorts clientspecified" > "$tmp"
    cat "$SSHD" >> "$tmp"
    mv "$tmp" "$SSHD"
    ok "GatewayPorts clientspecified written at top of $SSHD"

    restart_sshd
    sleep 1

    # Hard verify using runtime effective config
    local gp
    gp=$(sshd -T 2>/dev/null | awk '/^gatewayports/{print $2}')
    if [[ "$gp" == "clientspecified" || "$gp" == "yes" ]]; then
        ok "Verified runtime GatewayPorts=${gp}"
        return 0
    else
        err "GatewayPorts is '${gp}' — automatic fix failed!"
        echo ""
        warn "Fix manually on the VPS:"
        info "  grep -ri gatewayports /etc/ssh/"
        info "  Remove any 'GatewayPorts no' lines"
        info "  Add: GatewayPorts clientspecified"
        info "  systemctl restart ssh"
        echo ""
        return 1
    fi
}

# ─────────────────────────────────────────────────────
#  Check if a port is bound on 0.0.0.0 (not 127.0.0.1)
#  Uses /proc/net/tcp + tcp6 — no ss/netstat needed
# ─────────────────────────────────────────────────────

port_on_all_interfaces() {
    local port="$1"
    local hex_port
    hex_port=$(printf '%04X' "$port")

    # /proc/net/tcp — IPv4
    # 00000000:PPPP = 0.0.0.0 (all interfaces) = good
    if [[ -r /proc/net/tcp ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*sl ]] && continue
            local la; la=$(echo "$line" | awk '{print $2}')
            [[ "${la##*:}" == "$hex_port" ]] || continue
            [[ "${la%:*}" == "00000000" ]] && return 0
        done < /proc/net/tcp
    fi

    # /proc/net/tcp6 — IPv6
    # 00000000000000000000000000000000 = :: (all interfaces) = good
    if [[ -r /proc/net/tcp6 ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*sl ]] && continue
            local la; la=$(echo "$line" | awk '{print $2}')
            [[ "${la##*:}" == "$hex_port" ]] || continue
            [[ "${la%:*}" == "00000000000000000000000000000000" ]] && return 0
        done < /proc/net/tcp6
    fi

    return 1
}

# Returns the current bind address of a port (human readable)
port_bind_addr() {
    local port="$1"
    local hex_port
    hex_port=$(printf '%04X' "$port")

    if [[ -r /proc/net/tcp ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*sl ]] && continue
            local la; la=$(echo "$line" | awk '{print $2}')
            [[ "${la##*:}" == "$hex_port" ]] || continue
            local addr="${la%:*}"
            case "$addr" in
                00000000) echo "0.0.0.0"; return ;;
                0100007F) echo "127.0.0.1"; return ;;
                *)        echo "$addr"; return ;;
            esac
        done < /proc/net/tcp
    fi

    echo "not listening"
}

# ─────────────────────────────────────────────────────
#  SERVER SETUP  (VPS side)
# ─────────────────────────────────────────────────────

setup_server() {
    banner
    echo -e "${BOLD}  ► Server Setup  (VPS / Kharej)${NC}"
    hr

    # Fix GatewayPorts everywhere
    fix_gateway_ports
    local gp_ok=$?

    # Other sshd settings
    local SSHD="/etc/ssh/sshd_config"
    set_sshd_kv() {
        sed -i "/^[[:space:]]*#*[[:space:]]*${1}\b/Id" "$SSHD"
        echo "${1} ${2}" >> "$SSHD"
    }
    set_sshd_kv "AllowTcpForwarding"  "yes"
    set_sshd_kv "ClientAliveInterval" "30"
    set_sshd_kv "ClientAliveCountMax" "6"
    restart_sshd

    echo ""
    echo -e "  How many tunnel ports? ${DIM}(1–20, default 1)${NC}"
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
            iptables -A INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
                && ok "iptables: port $p/tcp opened"
        fi
    done

    hr
    ok "Server ready! Tunnel ports: ${PORTS[*]}"
    echo ""

    if [[ $gp_ok -ne 0 ]]; then
        warn "GatewayPorts could not be set automatically."
        warn "Tunnels will bind on 127.0.0.1 instead of 0.0.0.0 until you fix it:"
        info "  1. grep -ri gatewayports /etc/ssh/"
        info "  2. Remove any 'GatewayPorts no' lines from all files shown"
        info "  3. Add 'GatewayPorts clientspecified' to /etc/ssh/sshd_config"
        info "  4. systemctl restart ssh"
        echo ""
    fi

    info "Now run setup.sh on the Iran server and choose 'Client Setup'."
    echo ""

    # ── Wait for Iran to connect — poll /proc/net/tcp for 0.0.0.0 bind ──
    echo -e "  ${BOLD}Waiting for Iran client to connect...${NC}"
    echo -e "  ${DIM}(Ctrl+C to skip)${NC}"
    echo ""

    local max_wait=300
    local elapsed=0
    local all_up=0

    while [[ $elapsed -lt $max_wait ]]; do
        all_up=1
        for p in "${PORTS[@]}"; do
            port_on_all_interfaces "$p" || { all_up=0; break; }
        done

        if [[ $all_up -eq 1 ]]; then
            echo ""
            ok "All tunnel ports are up on 0.0.0.0!"
            for p in "${PORTS[@]}"; do
                ok "  0.0.0.0:${p} ✓"
            done
            echo ""
            break
        fi

        local status_line="  [${elapsed}s]"
        for p in "${PORTS[@]}"; do
            port_on_all_interfaces "$p" \
                && status_line+=" ${p}[UP]" \
                || status_line+=" ${p}[wait]"
        done
        printf "\r%-70s" "$status_line"

        sleep 2
        (( elapsed += 2 ))
    done

    # ── Timeout: show exactly what's wrong ───────────────────────────────
    if [[ $all_up -eq 0 ]]; then
        echo ""
        echo ""
        warn "Iran client did not connect within ${max_wait}s"
        echo ""
        for p in "${PORTS[@]}"; do
            local bound
            bound=$(port_bind_addr "$p")
            case "$bound" in
                "0.0.0.0")
                    ok "Port $p: bound to 0.0.0.0 ✓"
                    ;;
                "127.0.0.1")
                    err "Port $p: bound to 127.0.0.1 only — GatewayPorts not working"
                    warn "  Fix on VPS:"
                    info "    grep -ri gatewayports /etc/ssh/"
                    info "    Ensure: GatewayPorts clientspecified"
                    info "    Then:   systemctl restart ssh"
                    info "    Then on Iran: systemctl restart ssh-tunnel"
                    ;;
                "not listening")
                    warn "Port $p: nothing listening — Iran client not connected yet"
                    ;;
                *)
                    warn "Port $p: bound to unknown addr (${bound})"
                    ;;
            esac
        done
    fi

    echo ""
    read -rp "  [Press Enter to return to menu]"
}

# ─────────────────────────────────────────────────────
#  SOCKS5 proxy
# ─────────────────────────────────────────────────────

ask_proxy() {
    echo ""
    echo -e "  ${BOLD}Proxy Configuration${NC}"
    echo -e "  Do you have a SOCKS5 proxy to reach the VPS?"
    echo -e "  ${DIM}(Required if outbound is restricted on this server)${NC}"
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
        read -rp "  SOCKS5 address (e.g. 127.0.0.1:1080): " PROXY_ADDR
        [[ -z "$PROXY_ADDR" ]] && { err "Proxy address required"; exit 1; }
        local ph="${PROXY_ADDR%:*}" pp="${PROXY_ADDR##*:}"
        [[ -z "$ph" || -z "$pp" ]] && { err "Format: host:port"; exit 1; }
        PROXY_CMD="ProxyCommand=nc -x ${ph}:${pp} -X 5 %h %p"
        APT_PROXY_ARGS="-o Acquire::http::proxy=\"socks5h://${PROXY_ADDR}\" -o Acquire::https::proxy=\"socks5h://${PROXY_ADDR}\""
        ok "SOCKS5 proxy: $PROXY_ADDR"
    fi
}

# ─────────────────────────────────────────────────────
#  Install deps (proxy-aware)
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
                eval apt-get install -y "${pkgs[@]}" -q "$APT_PROXY_ARGS" 2>/dev/null
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
            warn "Cannot auto-install ${pkgs[*]} — install manually"
        fi
    fi
    ok "Dependencies OK"
}

# ─────────────────────────────────────────────────────
#  CLIENT SETUP  (Iran side)
# ─────────────────────────────────────────────────────

ask_auth() {
    echo ""
    echo -e "  ${BOLD}Authentication${NC}"
    echo ""
    echo "    1) Password  — script copies SSH key automatically"
    echo "    2) Key-based — key already on remote server"
    echo ""
    read -rp "  Choice [1/2, default 1]: " AUTH_CHOICE
    AUTH_CHOICE=${AUTH_CHOICE:-1}

    REMOTE_PASS=""
    if [[ "$AUTH_CHOICE" == "1" ]]; then
        read -rsp "  SSH password for remote server: " REMOTE_PASS
        echo ""
        [[ -z "$REMOTE_PASS" ]] && { err "Password required"; exit 1; }
        ok "Password received"
    else
        ok "Key-based — no password needed"
    fi
}

copy_ssh_key() {
    local REMOTE_USER="$1" REMOTE_HOST="$2" SSH_PORT="$3"
    local PROXY_CMD="$4" REMOTE_PASS="$5"

    [[ ! -f ~/.ssh/id_rsa ]] && {
        step "Generating SSH key..."
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa -q
        ok "SSH key created"
    } || ok "SSH key found: ~/.ssh/id_rsa"

    if [[ -n "$REMOTE_PASS" ]] && ! command -v sshpass &>/dev/null; then
        step "Installing sshpass..."
        install_deps
        if ! command -v sshpass &>/dev/null; then
            err "sshpass not available — add key manually:"
            echo -e "  ${YELLOW}$(cat ~/.ssh/id_rsa.pub)${NC}"
            read -rp "  Press Enter after adding the key: "
            return
        fi
    fi

    step "Copying SSH key to remote..."
    local args=()
    [[ -n "$PROXY_CMD" ]] && args+=(-o "$PROXY_CMD")
    args+=(-o "StrictHostKeyChecking=no" -p "$SSH_PORT")

    if [[ -n "$REMOTE_PASS" ]]; then
        SSHPASS="$REMOTE_PASS" sshpass -e ssh-copy-id "${args[@]}" "${REMOTE_USER}@${REMOTE_HOST}"
    else
        ssh-copy-id "${args[@]}" "${REMOTE_USER}@${REMOTE_HOST}"
    fi

    if [[ $? -eq 0 ]]; then
        ok "SSH key installed — passwordless login active"
    else
        warn "ssh-copy-id failed — add key manually:"
        echo -e "  ${YELLOW}$(cat ~/.ssh/id_rsa.pub)${NC}"
        read -rp "  Press Enter after adding the key: "
    fi
}

wait_for_connection() {
    local REMOTE_HOST="$1" SSH_PORT="$2" PROXY_CMD="$3" REMOTE_USER="$4"
    local max=60 elapsed=0

    step "Testing SSH connection to ${REMOTE_HOST}:${SSH_PORT}..."
    while [[ $elapsed -lt $max ]]; do
        local args=()
        [[ -n "$PROXY_CMD" ]] && args+=(-o "$PROXY_CMD")
        args+=(-o "StrictHostKeyChecking=no" -o "ConnectTimeout=5" -o "BatchMode=yes" -p "$SSH_PORT")
        ssh "${args[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "exit" 2>/dev/null && {
            echo ""; ok "Connected to ${REMOTE_HOST}!"; return 0
        }
        printf "\r  Attempt %d/%d..." "$((elapsed+1))" "$max"
        sleep 1; (( elapsed++ ))
    done
    echo ""; err "Cannot connect to ${REMOTE_HOST}:${SSH_PORT}"; return 1
}

generate_tunnel_script() {
    step "Generating tunnel runner script..."
    cat > "$TUNNEL_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# Auto-generated by SSH Tunnel Manager v2.3
CONFIG_DIR="/etc/ssh-tunnel"
TUNNELS_FILE="$CONFIG_DIR/tunnels.conf"
LOG_FILE="$CONFIG_DIR/tunnel.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG_FILE"; }

run_tunnel() {
    IFS='|' read -r ID REMOTE_USER REMOTE_HOST SSH_PORT TUNNEL_PORT LOCAL_PORT PROXY_CMD <<< "$1"
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
        log "[TUNNEL $ID] Connecting..."
        ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}"
        log "[TUNNEL $ID] Disconnected. Retry in 5s..."
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
    ok "Service installed and enabled"
}

setup_client() {
    banner
    echo -e "${BOLD}  ► Client Setup  (Iran / restricted server)${NC}"
    hr
    ensure_config_dir

    ask_proxy
    install_deps

    echo ""
    echo -e "  ${BOLD}Remote VPS${NC}"
    read -rp "  SSH host (IP or domain): " REMOTE_HOST
    [[ -z "$REMOTE_HOST" ]] && { err "Host required"; exit 1; }
    read -rp "  SSH user [default root]: " REMOTE_USER
    REMOTE_USER=${REMOTE_USER:-root}
    read -rp "  SSH port [default 22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}

    ask_auth

    echo ""
    echo -e "  ${BOLD}Tunnel Ports${NC}"
    echo -e "  How many tunnels? ${DIM}(1–20, default 1)${NC}"
    read -rp "  Count: " TUNNEL_COUNT
    TUNNEL_COUNT=${TUNNEL_COUNT:-1}
    [[ ! "$TUNNEL_COUNT" =~ ^[0-9]+$ || "$TUNNEL_COUNT" -lt 1 || "$TUNNEL_COUNT" -gt 20 ]] \
        && { err "Invalid"; exit 1; }

    local ENTRIES=()
    for (( i=1; i<=TUNNEL_COUNT; i++ )); do
        echo ""
        echo -e "  ${CYAN}── Tunnel #${i} ──${NC}"
        local def=$(( 20000 + i - 1 ))
        read -rp "  Remote port on VPS [default ${def}]: " TUNNEL_PORT
        TUNNEL_PORT=${TUNNEL_PORT:-$def}
        read -rp "  Local port to forward [default ${TUNNEL_PORT}]: " LOCAL_PORT
        LOCAL_PORT=${LOCAL_PORT:-$TUNNEL_PORT}
        ENTRIES+=("${REMOTE_HOST}:${TUNNEL_PORT}|${REMOTE_USER}|${REMOTE_HOST}|${SSH_PORT}|${TUNNEL_PORT}|${LOCAL_PORT}|${PROXY_CMD}")
        ok "Tunnel #${i}: local:${LOCAL_PORT} → ${REMOTE_HOST}:${TUNNEL_PORT}"
    done

    copy_ssh_key "$REMOTE_USER" "$REMOTE_HOST" "$SSH_PORT" "$PROXY_CMD" "$REMOTE_PASS"

    wait_for_connection "$REMOTE_HOST" "$SSH_PORT" "$PROXY_CMD" "$REMOTE_USER" || {
        err "Connection failed — aborting"; exit 1
    }

    step "Saving config..."
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
        echo -e "${GREEN}${BOLD}  ✓ Setup complete! ${TUNNEL_COUNT} tunnel(s) active.${NC}"
    else
        warn "Service may have issues — check: journalctl -u ssh-tunnel -f"
    fi
    echo ""
    info "Status: systemctl status ssh-tunnel"
    info "Logs:   journalctl -u ssh-tunnel -f"
    echo ""
    read -rp "  [Press Enter to return to menu]"
}

# ─────────────────────────────────────────────────────
#  TUNNEL MANAGEMENT
# ─────────────────────────────────────────────────────

list_tunnels() {
    echo ""
    if [[ ! -s "$TUNNELS_FILE" ]]; then
        warn "No tunnels configured."; return 1
    fi
    local i=1
    echo -e "  ${BOLD}Configured Tunnels:${NC}"
    hr
    printf "  %-4s %-22s %-10s %-13s %-12s %-10s %s\n" \
        "#" "Remote Host" "SSH Port" "Tunnel Port" "Local Port" "Proxy" "Status"
    hr
    while IFS='|' read -r ID RU RH SP TP LP PC; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        local proxy_label="none"; [[ -n "$PC" ]] && proxy_label="socks5"
        local st
        systemctl is-active ssh-tunnel &>/dev/null \
            && st="${GREEN}active${NC}" || st="${RED}stopped${NC}"
        printf "  %-4s %-22s %-10s %-13s %-12s %-10s " "$i" "$RH" "$SP" "$TP" "$LP" "$proxy_label"
        echo -e "$st"
        (( i++ ))
    done < "$TUNNELS_FILE"
    echo ""
}

delete_tunnel() {
    list_tunnels || return
    read -rp "  Tunnel number to delete (0 = cancel): " N
    [[ "$N" == "0" || -z "$N" ]] && return
    local i=1 NEW=""
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$i" -ne "$N" ]] && NEW+="${line}\n" || ok "Tunnel #${N} removed"
        (( i++ ))
    done < "$TUNNELS_FILE"
    printf "%b" "$NEW" > "$TUNNELS_FILE"
    generate_tunnel_script
    systemctl restart ssh-tunnel && ok "Service restarted"
}

edit_tunnel() {
    list_tunnels || return
    read -rp "  Tunnel number to edit (0 = cancel): " N
    [[ "$N" == "0" || -z "$N" ]] && return
    local i=1 FOUND=0 NEW=""
    while IFS='|' read -r ID RU RH SP TP LP PC; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        if [[ "$i" -eq "$N" ]]; then
            FOUND=1
            echo ""
            echo -e "  ${BOLD}Edit Tunnel #${N}${NC}  (Enter = keep current)"
            read -rp "  Remote host  [${RH}]: " v; RH=${v:-$RH}
            read -rp "  SSH user     [${RU}]: " v; RU=${v:-$RU}
            read -rp "  SSH port     [${SP}]: " v; SP=${v:-$SP}
            read -rp "  Tunnel port  [${TP}]: " v; TP=${v:-$TP}
            read -rp "  Local port   [${LP}]: " v; LP=${v:-$LP}
            local cur_p="none"; [[ -n "$PC" ]] && cur_p="$PC"
            echo -e "  Current proxy: ${DIM}${cur_p}${NC}"
            read -rp "  New SOCKS5 (host:port), 'none' to clear, Enter to keep: " NP
            if   [[ "$NP" == "none" ]]; then PC=""
            elif [[ -n "$NP" ]];        then PC="ProxyCommand=nc -x ${NP%:*}:${NP##*:} -X 5 %h %p"
            fi
            NEW+="${RH}:${TP}|${RU}|${RH}|${SP}|${TP}|${LP}|${PC}\n"
            ok "Tunnel #${N} updated"
        else
            NEW+="${ID}|${RU}|${RH}|${SP}|${TP}|${LP}|${PC}\n"
        fi
        (( i++ ))
    done < "$TUNNELS_FILE"
    [[ $FOUND -eq 0 ]] && { err "Not found"; return; }
    printf "%b" "$NEW" > "$TUNNELS_FILE"
    generate_tunnel_script
    systemctl restart ssh-tunnel && ok "Service restarted"
}

uninstall_all() {
    banner
    echo -e "${BOLD}  ► Uninstall${NC}"; hr; echo ""
    warn "This will remove the service, script, and config."
    read -rp "  Type 'yes' to confirm: " C
    [[ "$C" != "yes" ]] && { warn "Cancelled."; sleep 1; return; }
    systemctl stop    ssh-tunnel 2>/dev/null; ok "Stopped"
    systemctl disable ssh-tunnel 2>/dev/null; ok "Disabled"
    rm -f  "$SERVICE_FILE"  && ok "Unit removed"
    rm -f  "$TUNNEL_SCRIPT" && ok "Script removed"
    rm -rf "$CONFIG_DIR"    && ok "Config removed"
    systemctl daemon-reload
    echo ""; ok "Uninstall complete!"; echo ""; exit 0
}

# ─────────────────────────────────────────────────────
#  MAIN MENU
# ─────────────────────────────────────────────────────

main() {
    require_root
    ensure_config_dir

    while true; do
        banner
        systemctl is-active ssh-tunnel &>/dev/null \
            && echo -e "  Service: ${GREEN}${BOLD}RUNNING${NC}" \
            || echo -e "  Service: ${RED}${BOLD}STOPPED${NC}"
        echo ""; hr; echo ""
        echo "  1) Client Setup   — Iran server creates tunnel to VPS"
        echo "  2) Server Setup   — VPS receives tunnel"
        echo "  3) List tunnels"
        echo "  4) Edit tunnel"
        echo "  5) Delete tunnel"
        echo "  6) Restart service"
        echo "  7) View live logs"
        echo "  8) Uninstall"
        echo "  0) Exit"
        echo ""; hr
        read -rp "  Choice: " CHOICE
        case "$CHOICE" in
            1) setup_client ;;
            2) setup_server ;;
            3) list_tunnels; read -rp "  [Enter to continue]" ;;
            4) edit_tunnel;  read -rp "  [Enter to continue]" ;;
            5) delete_tunnel; read -rp "  [Enter to continue]" ;;
            6) systemctl restart ssh-tunnel && ok "Restarted"; sleep 1 ;;
            7) echo -e "  ${DIM}Ctrl+C to exit${NC}"; journalctl -u ssh-tunnel -f ;;
            8) uninstall_all ;;
            0) echo ""; exit 0 ;;
            *) warn "Invalid"; sleep 1 ;;
        esac
    done
}

main
