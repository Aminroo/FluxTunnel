#!/bin/bash

# =====================================================
#   FluxTunnel — SSH Reverse Tunnel Manager
#   Version : 0.3.0
#   GitHub  : https://github.com/Aminroo/FluxTunnel
#   Usage   : sudo bash setup.sh
# =====================================================

VERSION="0.3.0"
REPO_RAW="https://raw.githubusercontent.com/Aminroo/FluxTunnel/main/setup.sh"
REPO_VER="https://raw.githubusercontent.com/Aminroo/FluxTunnel/main/VERSION"

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
AUTH_FILE="$CONFIG_DIR/auth.conf"
KEY_FILE="$CONFIG_DIR/.enc_key"
TUNNEL_SCRIPT="/usr/local/bin/ssh-tunnel"
SERVICE_FILE="/etc/systemd/system/ssh-tunnel.service"
MODE_FILE="$CONFIG_DIR/mode"   # "client" یا "server"

# ─────────────────────────────────────────────────────
#  Print helpers
# ─────────────────────────────────────────────────────

banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║     FluxTunnel — SSH Reverse Tunnel          ║"
    printf "  ║     Version : %-31s║\n" "$VERSION"
    echo "  ║     Iran  →  VPS  (autossh + SOCKS5)        ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

step() { echo -e "${BLUE}[*]${NC} $1"; }
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${DIM}    $1${NC}"; }
hr()   { echo -e "${CYAN}${BOLD}──────────────────────────────────────────────${NC}"; }

require_root() {
    [[ $EUID -ne 0 ]] && { err "Run as root: sudo bash setup.sh"; exit 1; }
}

ensure_config_dir() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    [[ ! -f "$TUNNELS_FILE" ]] && touch "$TUNNELS_FILE"
    [[ ! -f "$AUTH_FILE"    ]] && touch "$AUTH_FILE"
    chmod 600 "$AUTH_FILE"
    # ایجاد کلید رمزنگاری یکتا در اولین اجرا
    if [[ ! -f "$KEY_FILE" ]]; then
        openssl rand -hex 32 > "$KEY_FILE" 2>/dev/null || \
            cat /proc/sys/kernel/random/uuid /proc/sys/kernel/random/uuid | sha256sum | awk '{print $1}' > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        ok "Encryption key generated: $KEY_FILE"
    fi
}

# ─────────────────────────────────────────────────────
#  Self-Update
# ─────────────────────────────────────────────────────

self_update() {
    banner
    echo -e "${BOLD}  ► Self Update${NC}"
    hr
    echo ""

    if ! command -v curl &>/dev/null; then
        err "curl is required for updates."
        info "Install: apt-get install -y curl"
        echo ""; read -rp "  [Press Enter to return]"; return 1
    fi

    local curl_opts=(-fsSL --max-time 15)
    [[ -n "${PROXY_ADDR:-}" ]] && curl_opts+=(--proxy "socks5h://${PROXY_ADDR}")

    step "Checking latest version from GitHub..."
    local remote_ver
    remote_ver=$(curl "${curl_opts[@]}" "$REPO_VER" 2>/dev/null | tr -d '[:space:]')

    if [[ -z "$remote_ver" ]]; then
        err "Cannot reach GitHub."
        echo ""
        warn "Manual update:"
        info "  curl -fsSL $REPO_RAW -o /tmp/setup_new.sh"
        info "  sudo bash /tmp/setup_new.sh"
        echo ""; read -rp "  [Press Enter to return]"; return 1
    fi

    echo -e "  Installed : ${BOLD}${VERSION}${NC}"
    echo -e "  Available : ${BOLD}${remote_ver}${NC}"
    echo ""

    if [[ "$remote_ver" == "$VERSION" ]]; then
        ok "Already up to date!"
        echo ""; read -rp "  [Press Enter to return]"; return 0
    fi

    echo -e "  ${YELLOW}New version: ${remote_ver}${NC}"
    read -rp "  Update now? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { warn "Cancelled."; sleep 1; return 0; }

    step "Downloading v${remote_ver}..."
    local tmp; tmp=$(mktemp /tmp/fluxtunnel-XXXXXX.sh)

    if curl "${curl_opts[@]}" "$REPO_RAW" -o "$tmp" 2>/dev/null && bash -n "$tmp" 2>/dev/null; then
        chmod +x "$tmp"
        local self; self=$(readlink -f "$0")
        cp "$self" "${self}.bak" && ok "Backup: ${self}.bak"
        cp "$tmp" "$self"
        rm -f "$tmp"
        ok "Updated to v${remote_ver}!"
        echo ""
        read -rp "  Restart now? [Y/n]: " restart
        [[ "${restart,,}" != "n" ]] && exec bash "$self"
    else
        err "Download failed or invalid script."
        rm -f "$tmp"
    fi

    echo ""; read -rp "  [Press Enter to return]"
}

# ─────────────────────────────────────────────────────
#  Password store — AES-256 با کلید تصادفی یکتا
#  کلید در /etc/ssh-tunnel/.enc_key (chmod 600)
#  فرمت هر خط: HOST:PORT:USER:ENC_DATA
# ─────────────────────────────────────────────────────

_enc_key() {
    # کلید تصادفی یکتا که هنگام نصب ساخته شده
    if [[ -f "$KEY_FILE" ]]; then
        cat "$KEY_FILE"
    else
        # fallback اگه فایل کلید نبود
        ensure_config_dir
        cat "$KEY_FILE"
    fi
}

save_password() {
    local host="$1" port="$2" user="$3" pass="$4"
    local key="${host}:${port}:${user}"
    local enc

    if command -v openssl &>/dev/null; then
        enc=$(printf '%s' "$pass" \
            | openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
              -pass "pass:$(_enc_key)" 2>/dev/null \
            | base64 -w0)
        if [[ -z "$enc" ]]; then
            warn "openssl encryption failed — saving as plaintext"
            enc="plain:$(printf '%s' "$pass" | base64 -w0)"
        fi
    else
        warn "openssl not found — saving password as plaintext (chmod 600)"
        enc="plain:$(printf '%s' "$pass" | base64 -w0)"
    fi

    # atomic write با فایل موقت
    local tmp_auth; tmp_auth=$(mktemp "${AUTH_FILE}.XXXXXX")
    grep -v "^${host}:${port}:${user}:" "$AUTH_FILE" 2>/dev/null > "$tmp_auth" || true
    echo "${key}:${enc}" >> "$tmp_auth"
    chmod 600 "$tmp_auth"
    mv "$tmp_auth" "$AUTH_FILE"
    ok "Password saved to $AUTH_FILE"
}

load_password() {
    local host="$1" port="$2" user="$3"
    local line; line=$(grep "^${host}:${port}:${user}:" "$AUTH_FILE" 2>/dev/null | head -1)
    [[ -z "$line" ]] && return 1

    local enc
    enc=$(echo "$line" | cut -d: -f4-)
    [[ -z "$enc" ]] && return 1

    if [[ "$enc" == plain:* ]]; then
        printf '%s' "${enc#plain:}" | base64 -d 2>/dev/null
    else
        printf '%s' "$enc" | base64 -d 2>/dev/null \
            | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
              -pass "pass:$(_enc_key)" 2>/dev/null
    fi
}

delete_password() {
    local host="$1" port="$2" user="$3"
    local tmp_auth; tmp_auth=$(mktemp "${AUTH_FILE}.XXXXXX")
    grep -v "^${host}:${port}:${user}:" "$AUTH_FILE" 2>/dev/null > "$tmp_auth" || true
    chmod 600 "$tmp_auth"
    mv "$tmp_auth" "$AUTH_FILE"
}

has_password() {
    local host="$1" port="$2" user="$3"
    grep -q "^${host}:${port}:${user}:" "$AUTH_FILE" 2>/dev/null
}

# ─────────────────────────────────────────────────────
#  Restart sshd
# ─────────────────────────────────────────────────────

restart_sshd() {
    for name in ssh sshd openssh-server; do
        if systemctl list-units --full --all 2>/dev/null | grep -q "^${name}\.service"; then
            systemctl restart "$name" && ok "sshd restarted ($name)" && return 0
        fi
    done
    systemctl restart ssh  2>/dev/null && ok "sshd restarted (ssh)"  && return 0
    systemctl restart sshd 2>/dev/null && ok "sshd restarted (sshd)" && return 0
    err "Could not restart sshd — run: systemctl restart ssh"
    return 1
}

# ─────────────────────────────────────────────────────
#  Fix GatewayPorts — با backup
# ─────────────────────────────────────────────────────

fix_gateway_ports() {
    local SSHD="/etc/ssh/sshd_config"

    # backup قبل از هر تغییر
    cp "$SSHD" "${SSHD}.fluxtunnel.bak" 2>/dev/null && \
        ok "Backup: ${SSHD}.fluxtunnel.bak"

    step "Scanning /etc/ssh/ for GatewayPorts conflicts..."
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$SSHD" ]] && continue  # فایل اصلی جداگانه مدیریت میشه
        cp "$f" "${f}.fluxtunnel.bak" 2>/dev/null
        sed -i "/^[[:space:]]*#*[[:space:]]*GatewayPorts\b/Id" "$f"
        ok "  Cleaned: $f"
    done < <(grep -rli "GatewayPorts" /etc/ssh/ 2>/dev/null)

    # حذف همه خطوط GatewayPorts از فایل اصلی و اضافه در بالا
    local tmp; tmp=$(mktemp)
    echo "GatewayPorts clientspecified" > "$tmp"
    grep -v "^[[:space:]]*#*[[:space:]]*GatewayPorts\b" "$SSHD" >> "$tmp"
    mv "$tmp" "$SSHD"
    chmod 600 "$SSHD"
    ok "GatewayPorts clientspecified → top of $SSHD"

    restart_sshd; sleep 1

    local gp; gp=$(sshd -T 2>/dev/null | awk '/^gatewayports/{print $2}')
    if [[ "$gp" == "clientspecified" || "$gp" == "yes" ]]; then
        ok "Verified runtime GatewayPorts=${gp}"; return 0
    else
        err "GatewayPorts='${gp}' — fix manually:"
        info "  grep -ri gatewayports /etc/ssh/"
        info "  Add: GatewayPorts clientspecified"
        info "  systemctl restart ssh"
        return 1
    fi
}

# ─────────────────────────────────────────────────────
#  Port helpers  (/proc/net — no ss/netstat needed)
# ─────────────────────────────────────────────────────

port_on_all_interfaces() {
    local port="$1"
    local hex; hex=$(printf '%04X' "$port")
    for f in /proc/net/tcp /proc/net/tcp6; do
        [[ -r "$f" ]] || continue
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*sl ]] && continue
            local la; la=$(awk '{print $2}' <<< "$line")
            [[ "${la##*:}" == "$hex" ]] || continue
            local addr="${la%:*}"
            [[ "$addr" == "00000000" || "$addr" == "00000000000000000000000000000000" ]] \
                && return 0
        done < "$f"
    done
    return 1
}

port_bind_addr() {
    local port="$1"
    local hex; hex=$(printf '%04X' "$port")
    [[ -r /proc/net/tcp ]] || { echo "not listening"; return; }
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*sl ]] && continue
        local la; la=$(awk '{print $2}' <<< "$line")
        [[ "${la##*:}" == "$hex" ]] || continue
        case "${la%:*}" in
            00000000) echo "0.0.0.0";   return ;;
            0100007F) echo "127.0.0.1"; return ;;
            *)        echo "${la%:*}";  return ;;
        esac
    done < /proc/net/tcp
    echo "not listening"
}

# ─────────────────────────────────────────────────────
#  SERVICE STATUS — تشخیص صحیح client یا server
# ─────────────────────────────────────────────────────

get_service_status() {
    local mode=""
    [[ -f "$MODE_FILE" ]] && mode=$(cat "$MODE_FILE")

    if [[ "$mode" == "server" ]]; then
        # روی VPS، سرویس tunnel نداریم — وضعیت پورت‌ها رو نشون بده
        echo "server"
    elif [[ "$mode" == "client" ]]; then
        # روی ایران، سرویس systemd داریم
        if systemctl is-active ssh-tunnel &>/dev/null; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        # هنوز setup نشده
        echo "not_configured"
    fi
}

show_status_line() {
    local mode=""
    [[ -f "$MODE_FILE" ]] && mode=$(cat "$MODE_FILE")
    local status; status=$(get_service_status)

    case "$status" in
        running)
            echo -e "  Mode    : ${CYAN}${BOLD}CLIENT (Iran)${NC}"
            echo -e "  Service : ${GREEN}${BOLD}RUNNING${NC}"
            ;;
        stopped)
            echo -e "  Mode    : ${CYAN}${BOLD}CLIENT (Iran)${NC}"
            echo -e "  Service : ${RED}${BOLD}STOPPED${NC}"
            ;;
        server)
            echo -e "  Mode    : ${CYAN}${BOLD}SERVER (VPS/Kharej)${NC}"
            # نمایش وضعیت پورت‌ها
            local has_ports=0
            if [[ -s "$TUNNELS_FILE" ]]; then
                while IFS='|' read -r ID RU RH SP TP LP PC; do
                    [[ -z "$ID" || "$ID" == \#* ]] && continue
                    if port_on_all_interfaces "$TP" 2>/dev/null; then
                        echo -e "  Port $TP : ${GREEN}${BOLD}OPEN (tunnel active)${NC}"
                        has_ports=1
                    else
                        echo -e "  Port $TP : ${YELLOW}${BOLD}WAITING for client${NC}"
                        has_ports=1
                    fi
                done < "$TUNNELS_FILE"
            fi
            [[ $has_ports -eq 0 ]] && echo -e "  Ports   : ${DIM}none configured${NC}"
            ;;
        not_configured)
            echo -e "  Mode    : ${DIM}Not configured yet${NC}"
            echo -e "  Service : ${DIM}N/A${NC}"
            ;;
    esac
}

# ─────────────────────────────────────────────────────
#  SERVER SETUP (VPS side)
# ─────────────────────────────────────────────────────

setup_server() {
    banner
    echo -e "${BOLD}  ► Server Setup  (VPS / Kharej)${NC}"
    hr

    fix_gateway_ports; local gp_ok=$?

    local SSHD="/etc/ssh/sshd_config"
    _set_sshd() {
        sed -i "/^[[:space:]]*#*[[:space:]]*${1}\b/Id" "$SSHD"
        echo "${1} ${2}" >> "$SSHD"
    }
    _set_sshd "AllowTcpForwarding"  "yes"
    _set_sshd "ClientAliveInterval" "10"
    _set_sshd "ClientAliveCountMax" "3"
    restart_sshd

    echo ""
    read -rp "  How many tunnel ports? (1–20, default 1): " PORT_COUNT
    PORT_COUNT=${PORT_COUNT:-1}
    [[ ! "$PORT_COUNT" =~ ^[0-9]+$ || "$PORT_COUNT" -lt 1 || "$PORT_COUNT" -gt 20 ]] \
        && { err "Invalid number"; exit 1; }

    local PORTS=()
    for (( i=1; i<=PORT_COUNT; i++ )); do
        local def=$(( 20000 + i - 1 ))
        read -rp "  Port #${i} [default ${def}]: " p; p=${p:-$def}
        [[ ! "$p" =~ ^[0-9]+$ || "$p" -lt 1024 || "$p" -gt 65535 ]] \
            && { err "Invalid port: $p"; exit 1; }
        PORTS+=("$p")
    done

    step "Opening firewall ports: ${PORTS[*]}"
    for p in "${PORTS[@]}"; do
        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            ufw allow "${p}/tcp" &>/dev/null && ok "ufw: $p/tcp"
        elif command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-port="${p}/tcp" &>/dev/null
            firewall-cmd --reload &>/dev/null && ok "firewalld: $p/tcp"
        else
            iptables -A INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null && ok "iptables: $p/tcp"
        fi
    done

    # ذخیره mode و پورت‌ها برای نمایش status
    echo "server" > "$MODE_FILE"
    # پاک کردن tunnels قدیمی و ذخیره پورت‌های جدید با فرمت مناسب server
    > "$TUNNELS_FILE"
    for (( i=0; i<${#PORTS[@]}; i++ )); do
        echo "$((i+1))|server|localhost|22|${PORTS[$i]}|${PORTS[$i]}|" >> "$TUNNELS_FILE"
    done

    hr; ok "Server ready! Ports: ${PORTS[*]}"; echo ""
    [[ $gp_ok -ne 0 ]] && warn "GatewayPorts not set automatically — fix manually (see above)"
    info "Now run setup.sh on the Iran server → Client Setup"
    echo ""

    echo -e "  ${BOLD}Waiting for Iran client...${NC}  ${DIM}(Ctrl+C to skip)${NC}"
    echo ""
    local max_wait=300 elapsed=0 all_up=0
    while [[ $elapsed -lt $max_wait ]]; do
        all_up=1
        for p in "${PORTS[@]}"; do port_on_all_interfaces "$p" || { all_up=0; break; }; done
        if [[ $all_up -eq 1 ]]; then
            echo ""; ok "All tunnel ports up on 0.0.0.0!"
            for p in "${PORTS[@]}"; do ok "  0.0.0.0:${p} ✓"; done
            echo ""; break
        fi
        local sl="  [${elapsed}s]"
        for p in "${PORTS[@]}"; do
            port_on_all_interfaces "$p" && sl+=" ${p}[UP]" || sl+=" ${p}[wait]"
        done
        printf "\r%-70s" "$sl"
        sleep 2; (( elapsed += 2 ))
    done

    if [[ $all_up -eq 0 ]]; then
        echo ""; echo ""; warn "Iran client did not connect within ${max_wait}s"; echo ""
        for p in "${PORTS[@]}"; do
            case "$(port_bind_addr "$p")" in
                "0.0.0.0")       ok   "Port $p: 0.0.0.0 ✓" ;;
                "127.0.0.1")     err  "Port $p: 127.0.0.1 only — GatewayPorts broken"
                                  info "  Fix: GatewayPorts clientspecified → systemctl restart ssh" ;;
                "not listening") warn "Port $p: not listening yet" ;;
                *)               warn "Port $p: unknown bind" ;;
            esac
        done
    fi

    echo ""; read -rp "  [Press Enter to return to menu]"
}

# ─────────────────────────────────────────────────────
#  SOCKS5 proxy ask
# ─────────────────────────────────────────────────────

ask_proxy() {
    echo ""
    echo -e "  ${BOLD}Proxy Configuration${NC}"
    echo -e "  ${DIM}Required if outbound SSH is blocked on this server${NC}"
    echo ""
    echo "    1) Yes — I have a SOCKS5 proxy"
    echo "    2) No  — connect directly"
    echo ""
    read -rp "  Choice [1/2, default 2]: " PROXY_CHOICE
    PROXY_CHOICE=${PROXY_CHOICE:-2}

    PROXY_CMD=""; PROXY_ADDR=""; APT_PROXY_ARGS=""

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
#  Install deps — nc, sshpass, autossh
# ─────────────────────────────────────────────────────

install_deps() {
    step "Checking dependencies..."
    local pkgs=()
    command -v nc      &>/dev/null || pkgs+=(netcat-openbsd)
    command -v sshpass &>/dev/null || pkgs+=(sshpass)
    command -v autossh &>/dev/null || pkgs+=(autossh)

    if [[ ${#pkgs[@]} -gt 0 ]]; then
        step "Installing: ${pkgs[*]}"

        if [[ -n "${PROXY_ADDR:-}" ]]; then
            # set کردن env variables برای همه ابزارها
            export http_proxy="socks5h://${PROXY_ADDR}"
            export https_proxy="socks5h://${PROXY_ADDR}"
            step "Using SOCKS5 proxy for install: socks5h://${PROXY_ADDR}"
        fi

        if command -v apt-get &>/dev/null; then
            if [[ -n "${PROXY_ADDR:-}" ]]; then
                # apt update با proxy
                step "Running apt update via proxy..."
                http_proxy="socks5h://${PROXY_ADDR}" \
                https_proxy="socks5h://${PROXY_ADDR}" \
                apt-get update -q \
                    -o Acquire::http::proxy="socks5h://${PROXY_ADDR}" \
                    -o Acquire::https::proxy="socks5h://${PROXY_ADDR}" \
                    2>/dev/null && ok "apt update done" || warn "apt update failed — trying install anyway"
                # apt install با proxy
                http_proxy="socks5h://${PROXY_ADDR}" \
                https_proxy="socks5h://${PROXY_ADDR}" \
                apt-get install -y -q "${pkgs[@]}" \
                    -o Acquire::http::proxy="socks5h://${PROXY_ADDR}" \
                    -o Acquire::https::proxy="socks5h://${PROXY_ADDR}" \
                    2>/dev/null
            else
                apt-get install -y -q "${pkgs[@]}" 2>/dev/null
            fi
        elif command -v yum &>/dev/null; then
            if [[ -n "${PROXY_ADDR:-}" ]]; then
                http_proxy="socks5h://${PROXY_ADDR}" \
                https_proxy="socks5h://${PROXY_ADDR}" \
                yum install -y -q "${pkgs[@]}" 2>/dev/null
            else
                yum install -y -q "${pkgs[@]}" 2>/dev/null
            fi
        else
            warn "Cannot auto-install ${pkgs[*]} — install manually"
        fi
    fi

    if command -v autossh &>/dev/null; then
        ok "autossh ready: $(autossh -V 2>&1 | head -1)"
    else
        warn "autossh not available — will use ssh fallback (brief reconnect gap possible)"
    fi
}

# ─────────────────────────────────────────────────────
#  CLIENT SETUP (Iran side)
# ─────────────────────────────────────────────────────

ask_auth() {
    echo ""
    echo -e "  ${BOLD}Authentication${NC}"
    echo ""
    echo "    1) Password  — copies SSH key automatically + saves password"
    echo "    2) Key-based — key already installed on remote"
    echo ""
    read -rp "  Choice [1/2, default 1]: " AUTH_CHOICE
    AUTH_CHOICE=${AUTH_CHOICE:-1}

    REMOTE_PASS=""
    if [[ "$AUTH_CHOICE" == "1" ]]; then
        if has_password "$REMOTE_HOST" "$SSH_PORT" "$REMOTE_USER"; then
            echo ""
            echo -e "  ${DIM}Saved password found for ${REMOTE_USER}@${REMOTE_HOST}:${SSH_PORT}${NC}"
            read -rp "  Use saved password? [Y/n]: " use_saved
            if [[ "${use_saved,,}" != "n" ]]; then
                REMOTE_PASS=$(load_password "$REMOTE_HOST" "$SSH_PORT" "$REMOTE_USER")
                ok "Using saved password."; return
            fi
        fi
        read -rsp "  SSH password for ${REMOTE_USER}@${REMOTE_HOST}: " REMOTE_PASS
        echo ""
        [[ -z "$REMOTE_PASS" ]] && { err "Password required"; exit 1; }
        ok "Password received"
    else
        ok "Key-based — no password needed"
    fi
}

copy_ssh_key() {
    local RU="$1" RH="$2" SP="$3" PC="$4" PASS="$5"

    [[ ! -f ~/.ssh/id_ed25519 ]] && [[ ! -f ~/.ssh/id_rsa ]] && {
        step "Generating SSH key (ed25519)..."
        ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q && ok "SSH key created: ~/.ssh/id_ed25519"
    } || ok "SSH key: exists"

    local KEY_PUB
    if   [[ -f ~/.ssh/id_ed25519.pub ]]; then KEY_PUB=~/.ssh/id_ed25519.pub
    elif [[ -f ~/.ssh/id_rsa.pub     ]]; then KEY_PUB=~/.ssh/id_rsa.pub
    else err "No public key found"; return 1
    fi

    if [[ -n "$PASS" ]] && ! command -v sshpass &>/dev/null; then
        install_deps
        if ! command -v sshpass &>/dev/null; then
            err "sshpass unavailable — add key manually:"
            echo -e "  ${YELLOW}$(cat "$KEY_PUB")${NC}"
            read -rp "  Press Enter after adding key: "; return
        fi
    fi

    step "Copying SSH key to ${RU}@${RH}..."
    local args=(); [[ -n "$PC" ]] && args+=(-o "$PC")
    # اولین بار با StrictHostKeyChecking=accept-new (ایمن‌تر از no)
    args+=(-o "StrictHostKeyChecking=accept-new" -p "$SP")

    local ok_flag=0
    if [[ -n "$PASS" ]]; then
        # پسورد از stdin به sshpass میره، نه از env
        echo "$PASS" | sshpass ssh-copy-id -f -i "$KEY_PUB" "${args[@]}" "${RU}@${RH}" 2>/dev/null \
            && ok_flag=1
    else
        ssh-copy-id -f -i "$KEY_PUB" "${args[@]}" "${RU}@${RH}" && ok_flag=1
    fi

    if [[ $ok_flag -eq 1 ]]; then
        ok "SSH key installed — passwordless login active"
        if [[ -n "$PASS" ]]; then
            read -rp "  Save password for future use? [Y/n]: " sv
            [[ "${sv,,}" != "n" ]] && save_password "$RH" "$SP" "$RU" "$PASS"
        fi
    else
        warn "ssh-copy-id failed — add key manually:"
        echo -e "  ${YELLOW}$(cat "$KEY_PUB")${NC}"
        read -rp "  Press Enter after adding key: "
    fi
}

wait_for_connection() {
    local RH="$1" SP="$2" PC="$3" RU="$4"
    step "Testing SSH to ${RH}:${SP}..."
    for (( i=1; i<=60; i++ )); do
        local args=(); [[ -n "$PC" ]] && args+=(-o "$PC")
        args+=(-o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=5" -o "BatchMode=yes" -p "$SP")
        ssh "${args[@]}" "${RU}@${RH}" "exit" 2>/dev/null \
            && { echo ""; ok "Connected to ${RH}!"; return 0; }
        printf "\r  Attempt %d/60..." "$i"; sleep 1
    done
    echo ""; err "Cannot connect to ${RH}:${SP}"; return 1
}

# ─────────────────────────────────────────────────────
#  Tunnel runner — autossh با fallback کامل
#  FIX: لاگ با flock برای thread safety
#  FIX: پسورد از stdin نه env
#  FIX: monitor port یکتا
# ─────────────────────────────────────────────────────

generate_tunnel_script() {
    step "Generating tunnel runner..."
    cat > "$TUNNEL_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# Auto-generated by FluxTunnel v0.3.0 — do not edit manually
CONFIG_DIR="/etc/ssh-tunnel"
TUNNELS_FILE="$CONFIG_DIR/tunnels.conf"
AUTH_FILE="$CONFIG_DIR/auth.conf"
KEY_FILE="$CONFIG_DIR/.enc_key"
LOG_FILE="$CONFIG_DIR/tunnel.log"
LOCK_FILE="$CONFIG_DIR/tunnel.lock"
MAX_LOG=2000

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    # flock برای جلوگیری از race condition
    (
        flock -w 2 200
        echo "$msg" >> "$LOG_FILE"
        local cnt; cnt=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if (( cnt > MAX_LOG )); then
            local tmp; tmp=$(mktemp "${LOG_FILE}.XXXXXX")
            tail -n $((MAX_LOG/2)) "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
        fi
    ) 200>"$LOCK_FILE"
}

_enc_key() {
    [[ -f "$KEY_FILE" ]] && cat "$KEY_FILE" && return
    # اگه کلید نبود، از machine-id به عنوان fallback
    local mid; mid=$(cat /etc/machine-id 2>/dev/null || hostname)
    printf '%s' "${mid}ssh-tunnel-key-fallback" | sha256sum | awk '{print $1}'
}

load_password() {
    local host="$1" port="$2" user="$3"
    local line; line=$(grep "^${host}:${port}:${user}:" "$AUTH_FILE" 2>/dev/null | head -1)
    [[ -z "$line" ]] && return 1
    local enc; enc=$(echo "$line" | cut -d: -f4-)
    [[ -z "$enc" ]] && return 1
    if [[ "$enc" == plain:* ]]; then
        printf '%s' "${enc#plain:}" | base64 -d 2>/dev/null
    else
        printf '%s' "$enc" | base64 -d 2>/dev/null \
            | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
              -pass "pass:$(_enc_key)" 2>/dev/null
    fi
}

run_tunnel() {
    IFS='|' read -r ID RU RH SP TP LP PC <<< "$1"

    # ─── ساخت ssh_config موقت برای این tunnel ───
    # راه‌حل: نوشتن همه تنظیمات در یه فایل ssh_config موقت
    # ProxyCommand در -o با autossh مشکل داره، اینجا درست کار می‌کنه
    local SSH_CFG="${CONFIG_DIR}/ssh_t${ID}.conf"
    {
        echo "Host ${RH}"
        echo "    Port ${SP}"
        echo "    User ${RU}"
        echo "    ServerAliveInterval 10"
        echo "    ServerAliveCountMax 3"
        echo "    ExitOnForwardFailure yes"
        echo "    StrictHostKeyChecking accept-new"
        echo "    ConnectTimeout 15"
        echo "    TCPKeepAlive yes"
        echo "    BatchMode yes"
        # ProxyCommand فقط اگه تنظیم شده باشه
        if [[ -n "$PC" ]]; then
            # PC فرمتش: "ProxyCommand=nc -x host:port -X 5 %h %p"
            # باید بدون = و بدون quotes بنویسیم
            local pc_val="${PC#ProxyCommand=}"
            echo "    ProxyCommand ${pc_val}"
        fi
    } > "$SSH_CFG"
    chmod 600 "$SSH_CFG"

    local BASE_OPTS=(
        -F "$SSH_CFG"
        -R "0.0.0.0:${TP}:127.0.0.1:${LP}"
    )

    # autossh با ProxyCommand در -F ssh_config سازگار نیست (No such file or directory)
    # راه‌حل: ssh مستقیم با reconnect loop — ServerAliveInterval وظیفه health-check داره
    log "[T${ID}] Starting ssh loop → ${RH}:${TP} (cfg:${SSH_CFG})"
    local backoff=5
    while true; do
        log "[T${ID}] Connecting..."

        # اول key-based (BatchMode=yes در ssh_config)
        ssh -N "${BASE_OPTS[@]}" "${RU}@${RH}" 2>/dev/null
        local exit_code=$?

        # اگه key کار نکرد، پسورد رو امتحان کن
        if [[ $exit_code -ne 0 ]]; then
            local pass; pass=$(load_password "$RH" "$SP" "$RU" 2>/dev/null)
            if [[ -n "$pass" ]] && command -v sshpass &>/dev/null; then
                echo "$pass" | sshpass ssh -N "${BASE_OPTS[@]}" \
                    -o BatchMode=no "${RU}@${RH}" 2>/dev/null
                exit_code=$?
            fi
        fi

        if [[ $exit_code -eq 0 ]]; then
            # اتصال بود و قطع شد — backoff رو ریست کن
            backoff=5
            log "[T${ID}] Disconnected — retry in ${backoff}s..."
        else
            log "[T${ID}] Connect failed (code=${exit_code}) — retry in ${backoff}s..."
        fi

        sleep "$backoff"
        (( backoff = backoff < 60 ? backoff * 2 : 60 ))
    done
}

# Launch all tunnels
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    run_tunnel "$line" &
done < "$TUNNELS_FILE"

log "FluxTunnel started — all tunnels launched (PID $$)"
wait
SCRIPT_EOF
    chmod +x "$TUNNEL_SCRIPT"
    ok "Tunnel runner: $TUNNEL_SCRIPT"
}

# ─────────────────────────────────────────────────────
#  systemd service
# ─────────────────────────────────────────────────────

generate_service() {
    step "Installing systemd service..."
    cat > "$SERVICE_FILE" << 'SVC_EOF'
[Unit]
Description=FluxTunnel — SSH Reverse Tunnel Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssh-tunnel
Restart=always
RestartSec=5
StartLimitIntervalSec=0
KillMode=process
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC_EOF
    systemctl daemon-reload
    systemctl enable ssh-tunnel &>/dev/null
    ok "Service enabled (Restart=always, StartLimitIntervalSec=0)"
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
    read -rp "  How many tunnels? (1–20, default 1): " TUNNEL_COUNT
    TUNNEL_COUNT=${TUNNEL_COUNT:-1}
    [[ ! "$TUNNEL_COUNT" =~ ^[0-9]+$ || "$TUNNEL_COUNT" -lt 1 || "$TUNNEL_COUNT" -gt 20 ]] \
        && { err "Invalid"; exit 1; }

    local ENTRIES=()
    for (( i=1; i<=TUNNEL_COUNT; i++ )); do
        echo ""
        echo -e "  ${CYAN}── Tunnel #${i} ──${NC}"
        local def=$(( 20000 + i - 1 ))
        read -rp "  Remote port on VPS  [default ${def}]: " TP; TP=${TP:-$def}
        read -rp "  Local port to fwd   [default ${TP}]: "  LP; LP=${LP:-$TP}
        ENTRIES+=("${i}|${REMOTE_USER}|${REMOTE_HOST}|${SSH_PORT}|${TP}|${LP}|${PROXY_CMD}")
        ok "Tunnel #${i}: local:${LP} → ${REMOTE_HOST}:${TP}"
    done

    copy_ssh_key "$REMOTE_USER" "$REMOTE_HOST" "$SSH_PORT" "$PROXY_CMD" "$REMOTE_PASS"
    wait_for_connection "$REMOTE_HOST" "$SSH_PORT" "$PROXY_CMD" "$REMOTE_USER" \
        || { err "Connection failed — aborting"; exit 1; }

    step "Saving tunnel config..."
    # ذخیره config با atomic write
    local tmp_cfg; tmp_cfg=$(mktemp "${TUNNELS_FILE}.XXXXXX")
    # کپی خطوط موجود
    [[ -s "$TUNNELS_FILE" ]] && cat "$TUNNELS_FILE" > "$tmp_cfg" || true
    for entry in "${ENTRIES[@]}"; do
        echo "$entry" >> "$tmp_cfg"
    done
    mv "$tmp_cfg" "$TUNNELS_FILE"
    ok "Config: $TUNNELS_FILE"

    # ذخیره mode
    echo "client" > "$MODE_FILE"

    generate_tunnel_script
    generate_service
    systemctl restart ssh-tunnel
    sleep 3

    hr
    if systemctl is-active ssh-tunnel &>/dev/null; then
        echo -e "${GREEN}${BOLD}  ✓ Setup complete! ${TUNNEL_COUNT} tunnel(s) active.${NC}"
    else
        warn "Service may have issues — check: journalctl -u ssh-tunnel -f"
    fi
    echo ""
    info "Status : systemctl status ssh-tunnel"
    info "Logs   : journalctl -u ssh-tunnel -f"
    echo ""; read -rp "  [Press Enter to return to menu]"
}

# ─────────────────────────────────────────────────────
#  Tunnel management
# ─────────────────────────────────────────────────────

list_tunnels() {
    echo ""
    if [[ ! -s "$TUNNELS_FILE" ]]; then
        warn "No tunnels configured."; return 1
    fi

    local mode=""
    [[ -f "$MODE_FILE" ]] && mode=$(cat "$MODE_FILE")

    echo -e "  ${BOLD}Configured Tunnels:${NC}"
    hr
    printf "  %-4s %-22s %-10s %-13s %-12s %-8s %-6s %s\n" \
        "#" "Remote Host" "SSH Port" "Tunnel Port" "Local Port" "Proxy" "PW" "Status"
    hr

    local i=1
    while IFS='|' read -r ID RU RH SP TP LP PC; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        [[ "$mode" == "server" && "$RH" == "localhost" ]] && RH="(this server)"
        local proxy="none"; [[ -n "$PC" ]] && proxy="socks5"
        local pw_st; has_password "$RH" "$SP" "$RU" && pw_st="${GREEN}yes${NC}" || pw_st="${DIM}no${NC}"

        local svc_st
        if [[ "$mode" == "client" ]]; then
            systemctl is-active ssh-tunnel &>/dev/null \
                && svc_st="${GREEN}active${NC}" || svc_st="${RED}stopped${NC}"
        elif [[ "$mode" == "server" ]]; then
            port_on_all_interfaces "$TP" 2>/dev/null \
                && svc_st="${GREEN}port open${NC}" || svc_st="${YELLOW}waiting${NC}"
        else
            svc_st="${DIM}N/A${NC}"
        fi

        printf "  %-4s %-22s %-10s %-13s %-12s %-8s " "$i" "$RH" "$SP" "$TP" "$LP" "$proxy"
        echo -e "${pw_st}  ${svc_st}"
        (( i++ ))
    done < "$TUNNELS_FILE"
    echo ""
}

delete_tunnel() {
    list_tunnels || return
    read -rp "  Tunnel # to delete (0=cancel): " N
    [[ "$N" == "0" || -z "$N" ]] && return
    local i=1
    local tmp_cfg; tmp_cfg=$(mktemp "${TUNNELS_FILE}.XXXXXX")
    while IFS='|' read -r ID RU RH SP TP LP PC; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        if [[ "$i" -eq "$N" ]]; then
            ok "Tunnel #${N} removed"
            read -rp "  Also delete saved password for ${RU}@${RH}? [y/N]: " dp
            [[ "${dp,,}" == "y" ]] && delete_password "$RH" "$SP" "$RU" && ok "Password removed"
        else
            echo "${ID}|${RU}|${RH}|${SP}|${TP}|${LP}|${PC}" >> "$tmp_cfg"
        fi
        (( i++ ))
    done < "$TUNNELS_FILE"
    mv "$tmp_cfg" "$TUNNELS_FILE"

    local mode=""
    [[ -f "$MODE_FILE" ]] && mode=$(cat "$MODE_FILE")
    if [[ "$mode" == "client" ]]; then
        generate_tunnel_script
        systemctl restart ssh-tunnel && ok "Service restarted"
    fi
}

edit_tunnel() {
    list_tunnels || return
    read -rp "  Tunnel # to edit (0=cancel): " N
    [[ "$N" == "0" || -z "$N" ]] && return
    local i=1 FOUND=0
    local tmp_cfg; tmp_cfg=$(mktemp "${TUNNELS_FILE}.XXXXXX")

    while IFS='|' read -r ID RU RH SP TP LP PC; do
        [[ -z "$ID" || "$ID" == \#* ]] && continue
        if [[ "$i" -eq "$N" ]]; then
            FOUND=1; echo ""
            echo -e "  ${BOLD}Edit Tunnel #${N}${NC}  (Enter = keep current)"
            local OLD_RH="$RH" OLD_SP="$SP" OLD_RU="$RU"
            read -rp "  Remote host  [${RH}]: " v; RH=${v:-$RH}
            read -rp "  SSH user     [${RU}]: " v; RU=${v:-$RU}
            read -rp "  SSH port     [${SP}]: " v; SP=${v:-$SP}
            read -rp "  Tunnel port  [${TP}]: " v; TP=${v:-$TP}
            read -rp "  Local port   [${LP}]: " v; LP=${v:-$LP}

            has_password "$OLD_RH" "$OLD_SP" "$OLD_RU" \
                && echo -e "  ${DIM}Password: saved ✓${NC}" \
                || echo -e "  ${DIM}Password: not saved${NC}"
            read -rsp "  New password (Enter=keep, type 'clear'=remove): " new_pw; echo ""

            # atomic: اول اطلاعات جدید ذخیره، بعد قدیمی حذف
            if [[ "$new_pw" == "clear" ]]; then
                delete_password "$OLD_RH" "$OLD_SP" "$OLD_RU"
                ok "Password cleared"
            elif [[ -n "$new_pw" ]]; then
                # اول ذخیره جدید
                save_password "$RH" "$SP" "$RU" "$new_pw"
                # بعد حذف قدیمی (اگه key عوض شده)
                if [[ "$OLD_RH$OLD_SP$OLD_RU" != "$RH$SP$RU" ]]; then
                    delete_password "$OLD_RH" "$OLD_SP" "$OLD_RU"
                fi
            fi

            local cur_p="none"; [[ -n "$PC" ]] && cur_p="$PC"
            echo -e "  Current proxy: ${DIM}${cur_p}${NC}"
            read -rp "  New SOCKS5 (host:port), 'none'=clear, Enter=keep: " NP
            if   [[ "$NP" == "none" ]]; then PC=""
            elif [[ -n "$NP" ]]; then PC="ProxyCommand=nc -x ${NP%:*}:${NP##*:} -X 5 %h %p"
            fi

            echo "${N}|${RU}|${RH}|${SP}|${TP}|${LP}|${PC}" >> "$tmp_cfg"
            ok "Tunnel #${N} updated"
        else
            echo "${ID}|${RU}|${RH}|${SP}|${TP}|${LP}|${PC}" >> "$tmp_cfg"
        fi
        (( i++ ))
    done < "$TUNNELS_FILE"

    if [[ $FOUND -eq 0 ]]; then
        rm -f "$tmp_cfg"
        err "Not found"; return
    fi

    mv "$tmp_cfg" "$TUNNELS_FILE"

    local mode=""
    [[ -f "$MODE_FILE" ]] && mode=$(cat "$MODE_FILE")
    if [[ "$mode" == "client" ]]; then
        generate_tunnel_script
        systemctl restart ssh-tunnel && ok "Service restarted"
    fi
}

manage_passwords() {
    banner
    echo -e "${BOLD}  ► Password Manager${NC}"
    hr; echo ""

    if [[ ! -s "$AUTH_FILE" ]]; then
        warn "No saved passwords."; echo ""; read -rp "  [Press Enter]"; return
    fi

    echo -e "  ${BOLD}Saved credentials (in $AUTH_FILE):${NC}"; echo ""
    local i=1
    declare -a ENTRIES
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local host port user
        IFS=':' read -r host port user _ <<< "$line"
        local pass; pass=$(load_password "$host" "$port" "$user" 2>/dev/null)
        if [[ -n "$pass" ]]; then
            printf "  ${GREEN}%2d)${NC} %-20s  %s@%s  ${DIM}[OK]${NC}\n" \
                "$i" "${host}:${port}" "$user" "$host"
        else
            printf "  ${YELLOW}%2d)${NC} %-20s  %s@%s  ${DIM}[decrypt failed]${NC}\n" \
                "$i" "${host}:${port}" "$user" "$host"
        fi
        ENTRIES+=("${host}:${port}:${user}")
        (( i++ ))
    done < "$AUTH_FILE"

    echo ""
    echo "  d) Delete a saved password"
    echo "  0) Back"
    echo ""
    read -rp "  Choice: " ch
    if [[ "$ch" == "d" ]]; then
        read -rp "  Entry # to delete: " dn
        local idx=$(( dn - 1 ))
        if [[ -n "${ENTRIES[$idx]:-}" ]]; then
            IFS=':' read -r dh dp du <<< "${ENTRIES[$idx]}"
            delete_password "$dh" "$dp" "$du"
            ok "Deleted: ${du}@${dh}:${dp}"
        else
            err "Invalid selection"
        fi
    fi
    echo ""; read -rp "  [Press Enter to return]"
}

uninstall_all() {
    banner
    echo -e "${BOLD}  ► Uninstall${NC}"; hr; echo ""
    warn "This will remove: service, script, tunnel config, and saved passwords."
    read -rp "  Type 'yes' to confirm: " C
    [[ "$C" != "yes" ]] && { warn "Cancelled."; sleep 1; return; }
    systemctl stop    ssh-tunnel 2>/dev/null; ok "Service stopped"
    systemctl disable ssh-tunnel 2>/dev/null; ok "Service disabled"
    rm -f  "$SERVICE_FILE"  && ok "Unit file removed"
    rm -f  "$TUNNEL_SCRIPT" && ok "Runner script removed"
    rm -rf "$CONFIG_DIR"    && ok "Config dir removed (tunnels + passwords)"
    systemctl daemon-reload
    echo ""; ok "Uninstall complete!"; echo ""; exit 0
}

# ─────────────────────────────────────────────────────
#  MAIN MENU
# ─────────────────────────────────────────────────────

main() {
    require_root
    ensure_config_dir
    PROXY_ADDR=""

    while true; do
        banner

        show_status_line
        local tcnt; tcnt=$(grep -c "^[^#]" "$TUNNELS_FILE" 2>/dev/null || echo 0)
        echo -e "  Tunnels : ${BOLD}${tcnt}${NC} configured"

        echo ""; hr; echo ""
        echo "  1)  Client Setup    — Iran server creates tunnel to VPS"
        echo "  2)  Server Setup    — VPS receives tunnel"
        echo "  3)  List tunnels"
        echo "  4)  Edit tunnel"
        echo "  5)  Delete tunnel"
        echo "  6)  Password manager"
        echo "  7)  Restart service"
        echo "  8)  View live logs"
        echo "  9)  Update script"
        echo "  10) Uninstall"
        echo "  0)  Exit"
        echo ""; hr
        read -rp "  Choice: " CHOICE
        case "$CHOICE" in
            1)  setup_client ;;
            2)  setup_server ;;
            3)  list_tunnels;  read -rp "  [Enter to continue]" ;;
            4)  edit_tunnel;   read -rp "  [Enter to continue]" ;;
            5)  delete_tunnel; read -rp "  [Enter to continue]" ;;
            6)  manage_passwords ;;
            7)
                local mode=""
                [[ -f "$MODE_FILE" ]] && mode=$(cat "$MODE_FILE")
                if [[ "$mode" == "client" ]]; then
                    systemctl restart ssh-tunnel && ok "Restarted"; sleep 1
                elif [[ "$mode" == "server" ]]; then
                    warn "Server mode — no tunnel service to restart"
                    info "Restart sshd? (y/N): "; read -rp "" rr
                    [[ "${rr,,}" == "y" ]] && restart_sshd
                else
                    warn "Not configured yet"
                fi
                sleep 1
                ;;
            8)
                local mode=""
                [[ -f "$MODE_FILE" ]] && mode=$(cat "$MODE_FILE")
                if [[ "$mode" == "client" ]]; then
                    echo -e "  ${DIM}Ctrl+C to exit${NC}"
                    journalctl -u ssh-tunnel -f
                elif [[ "$mode" == "server" ]]; then
                    echo -e "  ${DIM}Showing sshd logs — Ctrl+C to exit${NC}"
                    journalctl -u ssh -f 2>/dev/null || journalctl -u sshd -f
                else
                    warn "Not configured yet"
                    sleep 1
                fi
                ;;
            9)  self_update ;;
            10) uninstall_all ;;
            0)  echo ""; exit 0 ;;
            *)  warn "Invalid choice"; sleep 1 ;;
        esac
    done
}

main
