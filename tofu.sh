#!/usr/bin/env bash

export LANG=en_US.UTF-8
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
purple='\033[0;35m'
cyan='\033[0;36m'
plain='\033[0m'
bold='\033[1m'

CONFIG_DIR="/etc/tofu"
CONFIG_FILE="${CONFIG_DIR}/config.json"
DATA_FILE="${CONFIG_DIR}/node_info.env"
NODES_TXT="${CONFIG_DIR}/nodes.txt"
IPTABLES_SCRIPT="${CONFIG_DIR}/iptables.sh"
XRAY_BIN="/usr/local/bin/xray"
TOFU_BIN="/usr/local/bin/tofu"
SYSTEMD_FILE="/etc/systemd/system/tofu.service"
OPENRC_FILE="/etc/init.d/tofu"

DEFAULT_REALITY_PORT=443
DEFAULT_HY2_PORT=8443
DEFAULT_XHTTP_PORT=2053
DEFAULT_HOP_START=20000
DEFAULT_HOP_END=40000
DEFAULT_SNI_LIST=("gateway.icloud.com" "itunes.apple.com" "swdist.apple.com" "addons.mozilla.org" "www.samsung.com" "www.lovelive-anime.jp")

info() { echo -e "${cyan}[信息]${plain} $1"; }
success() { echo -e "${green}[成功]${plain} $1"; }
warn() { echo -e "${yellow}[警告]${plain} $1"; }
error() { echo -e "${red}[错误]${plain} $1"; }

show_logo() {
    echo -e "${cyan}"
    cat <<'EOF'
 ████████╗ ██████╗ ███████╗██╗   ██╗
 ╚══██╔══╝██╔═══██╗██╔════╝██║   ██║
    ██║   ██║   ██║█████╗  ██║   ██║
    ██║   ██║   ██║██╔══╝  ██║   ██║
    ██║   ╚██████╔╝██║     ╚██████╔╝
    ╚═╝    ╚═════╝ ╚═╝      ╚═════╝ 
   https://github.com/YGGYDW/ToFu
EOF
    echo -e "${plain}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 权限运行！请使用 sudo -i 或切换为 root 后再执行。"
        exit 1
    fi
}

check_arch() {
    local raw_arch
    raw_arch=$(uname -m)
    case "${raw_arch}" in
        x86_64 | amd64)
            ARCH="64"
            ARCH_NAME="amd64"
            ;;
        aarch64 | arm64)
            ARCH="arm64-v8a"
            ARCH_NAME="arm64"
            ;;
        *)
            error "目前不支持此 CPU 架构: ${raw_arch}"
            exit 1
            ;;
    esac
}

check_os() {
    if [[ -f /etc/redhat-release ]]; then
        OS_TYPE="centos"
        PKG_MANAGER="yum"
    elif grep -qi "ubuntu" /etc/os-release; then
        OS_TYPE="ubuntu"
        PKG_MANAGER="apt-get"
    elif grep -qi "debian" /etc/os-release; then
        OS_TYPE="debian"
        PKG_MANAGER="apt-get"
    elif grep -qi "alpine" /etc/os-release; then
        OS_TYPE="alpine"
        PKG_MANAGER="apk"
    else
        error "未受支持的操作系统类型，仅支持 Debian/Ubuntu/CentOS/Rocky/Alma/Alpine。"
        exit 1
    fi
}

install_deps() {
    info "正在安装必要的系统依赖组件..."
    if [[ "${PKG_MANAGER}" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y -q >/dev/null 2>&1
        apt-get install -y -q curl wget tar unzip jq openssl iptables iproute2 qrencode python3 >/dev/null 2>&1
    elif [[ "${PKG_MANAGER}" == "yum" ]]; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y curl wget tar unzip jq openssl iptables iproute qrencode python3 >/dev/null 2>&1
    elif [[ "${PKG_MANAGER}" == "apk" ]]; then
        apk update >/dev/null 2>&1
        apk add --no-cache curl wget tar unzip jq openssl iptables iproute2 bash python3 >/dev/null 2>&1
    fi
    success "基础依赖组件准备完毕。"
}

enable_bbr() {
    info "正在检测并优化系统 TCP BBR 加速..."
    touch /etc/sysctl.conf
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    success "Linux TCP BBR 内核加速已启用！"
}

get_public_ip() {
    info "正在智能获取服务器公网 IP..."
    IP=$(curl -s4m5 "https://api.ipify.org" || curl -s4m5 "https://icanhazip.com" || curl -s4m5 "https://ip.sb")
    if [[ -z "${IP}" ]]; then
        IP=$(curl -s6m5 "https://api64.ipify.org" || curl -s6m5 "https://icanhazip.com")
        IS_IPV6_ONLY=true
        warn "未检测到有效 IPv4 地址，将以 IPv6 地址模式继续: ${IP}"
    else
        IS_IPV6_ONLY=false
        success "检测到公网 IPv4: ${IP}"
    fi
}

scan_port_status() {
    local port=$1
    local proto=${2:-"tcp"}
    local name=""
    if command -v ss >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            if ss -uln | grep -q ":${port} "; then
                name=$(ss -ulpn "sport = :${port}" 2>/dev/null | awk 'NR>1 {print $NF}' | cut -d'"' -f2 | head -n1)
                echo "${name:-占用}"
                return 1
            fi
        else
            if ss -tln | grep -q ":${port} "; then
                name=$(ss -tlpn "sport = :${port}" 2>/dev/null | awk 'NR>1 {print $NF}' | cut -d'"' -f2 | head -n1)
                echo "${name:-占用}"
                return 1
            fi
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            if netstat -uln | grep -q ":${port} "; then
                echo "占用"
                return 1
            fi
        else
            if netstat -tln | grep -q ":${port} "; then
                echo "占用"
                return 1
            fi
        fi
    fi
    echo "可用"
    return 0
}

scan_and_display_ports() {
    echo -e "${cyan}[端口]${plain} 检查以下端口开放状态:"
    
    local http_ports=(80 8080 8880 2052 2082 2086 2095)
    local http_str=""
    for p in "${http_ports[@]}"; do
        local status
        status=$(scan_port_status "$p" "tcp")
        if [[ "$status" == "可用" ]]; then
            http_str+="${green}[✔ ${p}]${plain} "
        else
            http_str+="${red}[✖ ${p} ${status}]${plain} "
        fi
    done
    echo -e "  * 80系端口 (HTTP)  : ${http_str}"

    local https_ports=(443 2053 2083 2087 2096 8443)
    local https_str=""
    for p in "${https_ports[@]}"; do
        local status
        status=$(scan_port_status "$p" "tcp")
        if [[ "$status" == "可用" ]]; then
            https_str+="${green}[✔ ${p}]${plain} "
        else
            https_str+="${red}[✖ ${p} ${status}]${plain} "
        fi
    done
    echo -e "  * 443系端口 (HTTPS): ${https_str}"

    local udp_conflict_count=0
    if command -v ss >/dev/null 2>&1; then
        udp_conflict_count=$(ss -uln | awk '{print $5}' | awk -F: '{print $NF}' | awk '$1>=20000 && $1<=40000' | wc -l)
    fi
    if [[ "$udp_conflict_count" -eq 0 ]]; then
        echo -e "  * 端口跳跃段 (UDP) : ${green}[✔ 20000 ~ 40000 全部空闲可用 (共 20001 个端口)]${plain}"
    else
        echo -e "  * 端口跳跃段 (UDP) : ${yellow}[⚠ 20000 ~ 40000 检测到 ${udp_conflict_count} 个端口占用]${plain}"
    fi
}

configure_firewalls() {
    local p1=${1:-${PORT_REALITY:-443}}
    local p2=${2:-${PORT_HY2:-8443}}
    local p3=${3:-${PORT_XHTTP:-2053}}
    local hs=${4:-${PORT_HOP_START:-20000}}
    local he=${5:-${PORT_HOP_END:-40000}}

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
        info "检测到系统已启用 UFW 防火墙，正在自动放行端口..."
        ufw allow ${p1}/tcp >/dev/null 2>&1
        ufw allow ${p2}/udp >/dev/null 2>&1
        ufw allow ${p3}/tcp >/dev/null 2>&1
        ufw allow ${hs}:${he}/udp >/dev/null 2>&1
        success "UFW 端口规则已放行完毕。"
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        info "检测到系统已启用 Firewalld，正在自动放行端口..."
        firewall-cmd --zone=public --add-port=${p1}/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=${p2}/udp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=${p3}/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=${hs}-${he}/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        success "Firewalld 端口规则已放行完毕。"
    fi
}

check_port_occupied() {
    local port=$1
    local proto=${2:-"tcp"}
    if command -v ss >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            ss -uln | grep -q ":${port} "
        else
            ss -tln | grep -q ":${port} "
        fi
        return $?
    elif command -v netstat >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            netstat -uln | grep -q ":${port} "
        else
            netstat -tln | grep -q ":${port} "
        fi
        return $?
    fi
    return 1
}

find_free_port() {
    local start_port=${1:-10000}
    local port=$start_port
    local tries=0
    while [[ $tries -lt 500 ]]; do
        if ! check_port_occupied "$port" "tcp" && ! check_port_occupied "$port" "udp"; then
            echo "$port"
            return 0
        fi
        ((port++))
        ((tries++))
        if [[ $port -gt 65000 ]]; then
            port=10000
        fi
    done
    echo "$start_port"
}

install_xray_core() {
    info "正在从 GitHub 获取 Xray-core 官方最新正式版..."
    [[ -z "${ARCH}" ]] && check_arch

    local latest_tag
    latest_tag=$(curl -sSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r .tag_name 2>/dev/null)
    if [[ -z "${latest_tag}" || "${latest_tag}" == "null" ]]; then
        latest_tag="v25.1.30"
        warn "获取 GitHub 最新版本号失败，使用回退版本号: ${latest_tag}"
    fi

    local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${ARCH}.zip"
    info "下载地址: ${download_url}"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local dl_ok=false
    echo -e "${cyan}[下载]${plain} 正在拉取 Xray-core 官方核心软件包..."
    if curl -L --progress-bar "${download_url}" -o "${tmp_dir}/xray.zip"; then
        dl_ok=true
        echo -e "${green}.........................................✅${plain}"
    else
        local mirror_url="https://ghproxy.net/${download_url}"
        warn "官方直连较慢，正在切换镜像源拉取..."
        if curl -L --progress-bar "${mirror_url}" -o "${tmp_dir}/xray.zip"; then
            dl_ok=true
            echo -e "${green}.........................................✅${plain}"
        fi
    fi

    unzip -q -o "${tmp_dir}/xray.zip" -d "${tmp_dir}"
    if [[ ! -f "${tmp_dir}/xray" ]]; then
        error "解压 Xray 二进制失败！"
        rm -rf "${tmp_dir}"
        exit 1
    fi

    mkdir -p "${CONFIG_DIR}"
    mkdir -p "${CONFIG_DIR}/certs"
    cp -f "${tmp_dir}/xray" "${XRAY_BIN}"
    chmod +x "${XRAY_BIN}"

    mkdir -p /usr/local/share/xray
    if [[ -f "${tmp_dir}/geoip.dat" ]]; then
        cp -f "${tmp_dir}/geoip.dat" /usr/local/share/xray/
        cp -f "${tmp_dir}/geoip.dat" /usr/local/bin/
    fi
    if [[ -f "${tmp_dir}/geosite.dat" ]]; then
        cp -f "${tmp_dir}/geosite.dat" /usr/local/share/xray/
        cp -f "${tmp_dir}/geosite.dat" /usr/local/bin/
    fi

    rm -rf "${tmp_dir}"

    local installed_version
    installed_version=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}')
    success "Xray 官方内核已成功就绪: Version ${installed_version}"
}

probe_best_sni() {
    info "正在探测最优 REALITY 伪装域名（TLS 1.3 + H2 支持度）..."
    local best_sni=""
    local min_latency=999999

    for sni in "${DEFAULT_SNI_LIST[@]}"; do
        local latency
        latency=$(curl -s -w "%{time_connect}\n" -o /dev/null --connect-timeout 2 "https://${sni}" 2>/dev/null | awk '{print int($1 * 1000)}')
        if [[ -n "$latency" && "$latency" -gt 0 ]]; then
            if [[ "$latency" -lt "$min_latency" ]]; then
                min_latency=$latency
                best_sni=$sni
            fi
        fi
    done

    if [[ -z "$best_sni" ]]; then
        best_sni="gateway.icloud.com"
        info "采用备用可靠 SNI 域名: ${best_sni}"
    else
        success "选出延迟最低的最优 SNI: ${best_sni} (握手延迟: ${min_latency}ms)"
    fi
    REALITY_SNI="${best_sni}"
}

generate_credentials() {
    info "正在生成高强度加密凭证与密钥对..."
    UUID=$("${XRAY_BIN}" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    
    local key_pair
    key_pair=$("${XRAY_BIN}" x25519)
    REALITY_PRIVATE_KEY=$(echo "$key_pair" | grep -i "Private" | awk '{print $NF}')
    REALITY_PUBLIC_KEY=$(echo "$key_pair" | grep -i "Public" | awk '{print $NF}')
    REALITY_SHORT_ID=$(openssl rand -hex 4)

    info "正在生成 ECC P-256 自签名安全证书 (符合标准 SAN)..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "${CONFIG_DIR}/certs/ecc.key" \
        -out "${CONFIG_DIR}/certs/ecc.crt" \
        -subj "/CN=www.bing.com" -days 3650 \
        -addext "subjectAltName=DNS:www.bing.com" >/dev/null 2>&1

    CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "${CONFIG_DIR}/certs/ecc.crt" | cut -d'=' -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    success "凭证与证书生成完毕。"
}

setup_iptables_port_hopping() {
    info "正在配置 Hysteria 2 端口跳跃转发规则 (${PORT_HOP_START}:${PORT_HOP_END} -> ${PORT_HY2})..."
    cat > "${IPTABLES_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
ACTION=$1
TARGET_PORT=$2
START_PORT=${3:-20000}
END_PORT=${4:-40000}

[[ -z "${TARGET_PORT}" ]] && exit 1

enable_rules() {
    disable_rules
    iptables -t nat -A PREROUTING -p udp --dport ${START_PORT}:${END_PORT} -j REDIRECT --to-ports ${TARGET_PORT} 2>/dev/null
    ip6tables -t nat -A PREROUTING -p udp --dport ${START_PORT}:${END_PORT} -j REDIRECT --to-ports ${TARGET_PORT} 2>/dev/null || true
}

disable_rules() {
    iptables -t nat -D PREROUTING -p udp --dport ${START_PORT}:${END_PORT} -j REDIRECT --to-ports ${TARGET_PORT} 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -p udp --dport ${START_PORT}:${END_PORT} -j REDIRECT --to-ports ${TARGET_PORT} 2>/dev/null || true
}

case "${ACTION}" in
    enable) enable_rules ;;
    disable) disable_rules ;;
    *) echo "Usage: $0 {enable|disable} <target_port> [start_port] [end_port]" ;;
esac
EOF
    chmod +x "${IPTABLES_SCRIPT}"
    /bin/bash "${IPTABLES_SCRIPT}" enable "${PORT_HY2}" "${PORT_HOP_START}" "${PORT_HOP_END}"
    success "Hysteria 2 端口跳跃内核级 NAT 转发已就绪！"
}

generate_server_config() {
    info "正在合成服务端主配置文件 (${CONFIG_FILE})..."

    cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "::",
      "port": ${PORT_REALITY},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_SNI}:443",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            "${REALITY_SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "tag": "hysteria2",
      "listen": "::",
      "port": ${PORT_HY2},
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "clients": [
          {
            "auth": "${UUID}"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3"],
          "certificates": [
            {
              "certificateFile": "${CONFIG_DIR}/certs/ecc.crt",
              "keyFile": "${CONFIG_DIR}/certs/ecc.key"
            }
          ]
        }
      }
    },
    {
      "tag": "vless-xhttp",
      "listen": "::",
      "port": ${PORT_XHTTP},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
          "path": "/xraybox-${UUID}",
          "mode": "auto"
        },
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${CONFIG_DIR}/certs/ecc.crt",
              "keyFile": "${CONFIG_DIR}/certs/ecc.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "tag": "warp-socks",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40000
          }
        ]
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "vless-xhttp"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF

    info "执行 Xray 配置文件严格语法检查..."
    if ! "${XRAY_BIN}" -test -config "${CONFIG_FILE}" >/dev/null 2>&1; then
        error "配置文件检查未通过！详细日志如下："
        "${XRAY_BIN}" -test -config "${CONFIG_FILE}"
        exit 1
    fi
    success "配置文件静态检查通过 (100% 官方合规)。"
}

setup_system_service() {
    info "正在配置后台守护进程服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        cat > "${SYSTEMD_FILE}" <<EOF
[Unit]
Description=ToFu Anti-Censorship Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStartPre=-/bin/bash ${IPTABLES_SCRIPT} enable ${PORT_HY2} ${PORT_HOP_START} ${PORT_HOP_END}
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
ExecStopPost=-/bin/bash ${IPTABLES_SCRIPT} disable ${PORT_HY2} ${PORT_HOP_START} ${PORT_HOP_END}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable tofu >/dev/null 2>&1
        systemctl restart tofu
    elif command -v rc-service >/dev/null 2>&1 || [[ -f /etc/init.d/cron ]]; then
        cat > "${OPENRC_FILE}" <<EOF
#!/sbin/openrc-run
description="ToFu Service"
command="${XRAY_BIN}"
command_args="run -config ${CONFIG_FILE}"
pidfile="/run/tofu.pid"
command_background="yes"

start_pre() {
    /bin/bash ${IPTABLES_SCRIPT} enable ${PORT_HY2} ${PORT_HOP_START} ${PORT_HOP_END}
}

stop_post() {
    /bin/bash ${IPTABLES_SCRIPT} disable ${PORT_HY2} ${PORT_HOP_START} ${PORT_HOP_END}
}
EOF
        chmod +x "${OPENRC_FILE}"
        rc-update add tofu default >/dev/null 2>&1
        rc-service tofu restart
    else
        killall -9 xray >/dev/null 2>&1 || true
        nohup "${XRAY_BIN}" run -config "${CONFIG_FILE}" >/dev/null 2>&1 &
    fi
    success "ToFu 后台守护进程启动成功！"
}

save_env_data() {
    cat > "${DATA_FILE}" <<EOF
IP="${IP}"
UUID="${UUID}"
PORT_REALITY=${PORT_REALITY}
PORT_HY2=${PORT_HY2}
PORT_XHTTP=${PORT_XHTTP}
PORT_HOP_START=${PORT_HOP_START}
PORT_HOP_END=${PORT_HOP_END}
REALITY_SNI="${REALITY_SNI}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY}"
REALITY_SHORT_ID="${REALITY_SHORT_ID}"
CERT_SHA256="${CERT_SHA256}"
EOF
}

load_env_data() {
    if [[ -f "${DATA_FILE}" ]]; then
        source "${DATA_FILE}"
    elif [[ -f "/etc/xray-box/node_info.env" ]]; then
        source "/etc/xray-box/node_info.env"
    fi
}

generate_client_links() {
    local host_ip="${IP}"
    if [[ "${IP}" =~ : ]]; then
        host_ip="[${IP}]"
    fi

    LINK_REALITY="vless://${UUID}@${host_ip}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#%E3%80%90%E4%B8%BB%E5%8A%9B%E6%97%97%E8%88%B0%E3%80%91VLESS%20%2B%20REALITY%20%2B%20XTLS-Vision%20(%E6%97%A5%E5%B8%B8%E4%B8%BB%E5%8A%9B)"
    LINK_HY2="hysteria2://${UUID}@${host_ip}:${PORT_HY2}?ports=${PORT_HOP_START}-${PORT_HOP_END}&security=tls&alpn=h3&insecure=1&sni=www.bing.com#%E3%80%90%E5%BC%B1%E7%BD%91%E6%95%91%E6%98%9F%E3%80%91Hysteria%202%20(UDP%E7%AB%AF%E5%8F%A3%E8%B7%B3%E8%B7%83)"
    LINK_XHTTP="vless://${UUID}@${host_ip}:${PORT_XHTTP}?encryption=none&security=tls&sni=www.bing.com&type=xhttp&path=%2Fxraybox-${UUID}&mode=auto&insecure=1&pcs=${CERT_SHA256}&pinnedPeerCertSha256=${CERT_SHA256}#%E3%80%90%E5%AE%B9%E7%81%BE%E9%98%B2%E5%B0%81%E3%80%91VLESS%20%2B%20XHTTP%20%2B%20TLS%20(%E5%8F%AF%E5%A5%97CDN)"

    cat > "${NODES_TXT}" <<EOF
========================================================================
                      ToFu 节点配置直连与备份
========================================================================
【节点1】VLESS + REALITY + XTLS-Vision (日常主力)
${LINK_REALITY}

【节点2】Hysteria 2 (UDP端口跳跃)
${LINK_HY2}

【节点3】VLESS + XHTTP + TLS (可套CDN+WARP)
${LINK_XHTTP}
========================================================================
EOF
}

show_cdn_tutorial() {
    local return_target=${1:-"info"}
    clear
    echo -e "${cyan}========================================================================${plain}"
    echo -e "       🌐 为节点 3【VLESS + XHTTP + TLS】套 Cloudflare CDN 步骤说明"
	echo -e "       不明白什么是 CND 先回去看文档：https://github.com/YGGYDW/ToFu"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "注册域名并在 Cloudflare 托管（以下以二级域名bbb.aaa.com为例），完成此步请按回车 [Enter] 查看步骤 1..."
    read -r
    
    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "【步骤 1：添加 DNS 解析 A 记录】"
    echo -e "  1. 登录 Cloudflare 网页后台，在域名处点击【DNS】➔【记录】；"
    echo -e "  2. 点击【添加记录】："
    echo -e "     - 类型 (Type)     : A"
    echo -e "     - 名称 (Name)     : ccc (自定义前缀)"
    echo -e "     - IPv4 地址       : ${IP:-111.222.333.444} (当前服务器 IP)"
    echo -e "     - 代理状态 (Proxy): 开启【小黄云 ☁️ 已代理状态】"
    echo -e "  3. 点击保存。新添加的完整域名为：ccc.bbb.aaa.com\n"
    echo -e "${yellow}完成此步后，请按回车 [Enter] 查看步骤 2...${plain}"
    read -r

    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "【步骤 2：设置 SSL/TLS 为完全加密模式】"
    echo -e "  1. 点击 Cloudflare 左侧菜单【SSL/TLS】➔【概述】；"
    echo -e "  2. 将当前加密模式选择为：【完全】（Full，在部分中文面板显示为“完整”）。"
    echo -e "     （注：此模式下 Cloudflare 会加密到您的源服务器，接受自签名证书）"
    echo -e "     ⚠️ 切勿选择“灵活”，否则会导致重定向死循环。\n"
    echo -e "${yellow}完成此步后，请按回车 [Enter] 查看步骤 3...${plain}"
    read -r

    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "【步骤 3：配置源服务器规则 (Origin Rules) 端口重写到 2053】"
    echo -e "  1. 点击 Cloudflare 左侧菜单【规则】➔【概述】（或直接点击【源服务器规则 Origin Rules】）；"
    echo -e "  2. 点击【创建规则】："
    echo -e "     - 规则名称: 自定义填写（如：tofu-xhttp）"
    echo -e "     - 在“当传入请求匹配时...”区域："
    echo -e "       * 字段选择: 主机名 (Hostname) | 运算符: 等于 | 值: 填入 ccc.bbb.aaa.com"
    echo -e "       * 点击 Add 增加一行: 字段选择 SSL/HTTPS | 打开蓝色开关按钮"
    echo -e "       * 表达式预览将显示: (http.host eq \"ccc.bbb.aaa.com\" and ssl)"
    echo -e "     - 最下方目标端口:"
    echo -e "       * 选择【重写到...】，在右侧填空处填入: ${PORT_XHTTP:-2053}"
    echo -e "  3. 点击右下角【部署】保存。\n"
    echo -e "${yellow}完成此步后，请按回车 [Enter] 查看步骤 4...${plain}"
    read -r

    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "【步骤 4：客户端 (如 v2rayN) 编辑设置】"
    echo -e "  1. 在 Windows v2rayN 中双击打开导入的【容灾防封】节点编辑界面；"
    echo -e "  2. 修改以下基础连接信息："
    echo -e "     - 地址 (Address)  : 改为 ccc.bbb.aaa.com (或 Cloudflare 官方优选 IP)"
    echo -e "     - 端口 (Port)     : 改为 ${PORT_XHTTP:-2053} (或 Cloudflare 支持的 HTTPS 端口: 443、2083、2087、2096、8443)"
    echo -e "     - 伪装域名 (Host) : 改为 ccc.bbb.aaa.com"
    echo -e "     - SNI             : 改为 ccc.bbb.aaa.com"
    echo -e "  3. ${yellow}⚠️【关键操作·清除固定证书】（必做，否则真连接延迟必为 -1）：${plain}"
    echo -e "     - 找到【固定证书】选项，若右侧显示为“证书已设置”；"
    echo -e "     - 点击右侧【...】按钮打开窗口，将里面的【证书指纹】内容全选删除清空；"
    echo -e "     - 点击空白处关闭弹窗，此时状态显示为【证书未设置】即代表操作成功！"
    echo -e "     （原理：套 CDN 后面对的是 Cloudflare 官方受信任证书，无需比对 VPS 自签指纹）"
    echo -e "  4. 其余用户 ID、路径、底层传输设置保持不变，点击确定保存并测试即可！"
    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "教程阅读完毕，按回车 [Enter] 返回..."
    read -r
    if [[ "$return_target" == "cf_menu" ]]; then
        return 0
    elif [[ "$return_target" == "info" ]]; then
        show_node_info
    else
        main_menu
    fi
}

show_qr() {
    local title=$1
    local link=$2
    echo -e "\n${green}=== ${title} ===${plain}"
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "${link}"
    else
        warn "未检测到 qrencode 组件，无法在终端渲染二维码。"
    fi
}

show_node_info() {
    load_env_data
    generate_client_links

    clear
    echo -e "${cyan}========================================================================${plain}"
    echo -e "              ${bold}${green}🎉  ToFu 节点部署完成！${plain}"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "✅ 提示：双击或鼠标三击即可整行全选链接；或者三条链接全选复制；链接已同步写入 ${NODES_TXT}"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo -e "${bold}${yellow}【节点1】VLESS + REALITY + XTLS-Vision (日常主力)${plain}"
    echo -e "${cyan}${LINK_REALITY}${plain}"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo -e "${bold}${yellow}【节点2】Hysteria 2 (UDP端口跳跃)${plain}"
    echo -e "${cyan}${LINK_HY2}${plain}"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo -e "${bold}${yellow}【节点3】VLESS + XHTTP + TLS (可套CDN+WARP)${plain}"
    echo -e "${cyan}${LINK_XHTTP}${plain}"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "  ${green}1.${plain} 显示所有节点二维码 (依次输出 3 个节点二维码，回车默认)"
    echo -e "  ${green}2.${plain} 仅显示 【节点1】VLESS + REALITY 节点二维码"
    echo -e "  ${green}3.${plain} 仅显示 【节点2】Hysteria 2 (带端口跳跃) 节点二维码"
    echo -e "  ${green}4.${plain} 仅显示 【节点3】VLESS + XHTTP 节点二维码"
    echo -e "  ${green}5.${plain} Cloudflare CDN + WARP 专区"
    echo -e "  ${green}0.${plain} 返回管理菜单"
    echo -e "${cyan}========================================================================${plain}"
    read -rp "请输入选项 [默认: 1]: " qr_choice
    qr_choice=${qr_choice:-1}
    case "$qr_choice" in
        1)
            show_qr "【节点1】VLESS + REALITY + XTLS-Vision" "${LINK_REALITY}"
            show_qr "【节点2】Hysteria 2 (带端口跳跃)" "${LINK_HY2}"
            show_qr "【节点3】VLESS + XHTTP + TLS" "${LINK_XHTTP}"
            echo -e "\n按任意键返回管理菜单..."
            read -n 1 -s -r
            main_menu
            ;;
        2)
            show_qr "【节点1】VLESS + REALITY + XTLS-Vision" "${LINK_REALITY}"
            echo -e "\n按任意键返回管理菜单..."
            read -n 1 -s -r
            main_menu
            ;;
        3)
            show_qr "【节点2】Hysteria 2 (带端口跳跃)" "${LINK_HY2}"
            echo -e "\n按任意键返回管理菜单..."
            read -n 1 -s -r
            main_menu
            ;;
        4)
            show_qr "【节点3】VLESS + XHTTP + TLS" "${LINK_XHTTP}"
            echo -e "\n按任意键返回管理菜单..."
            read -n 1 -s -r
            main_menu
            ;;
        5)
            cloudflare_cdn_menu "info"
            ;;
        0)
            main_menu
            ;;
        *)
            main_menu
            ;;
    esac
}

install_all() {
    clear
    show_logo
    echo -e "${bold}${cyan}ToFu 节点部署运行中......${plain}"
    echo -e "${cyan}========================================================================${plain}"
    check_root
    check_arch
    check_os

    install_deps
    enable_bbr
    get_public_ip
    scan_and_display_ports

    echo -e "${cyan}========================================================================${plain}"
    echo -e "✅ 提示：如果你使用的是主流云服务商（如 AWS、甲骨文 Oracle、谷歌云 GCP、"
    echo -e "   腾讯云/阿里云国际、Hetzner、搬瓦工等），务必在云服务器后台的"
    echo -e "   “安全组 / 防火墙（Security Group / Firewall）”中至少开放以下端口："
    echo -e "   ✅ ${green}443、8443、2053、20000 ~ 40000${plain} (或自定义端口)"
    echo -e "✅ 提示：如果你的 VPS 是纯系统自带防火墙（无外部安全组拦截），"
    echo -e "   脚本内置程序会自动配置处理，无需手动操作。"
    echo -e "${cyan}========================================================================${plain}"

    echo -e "\n${bold}${cyan}ToFu 节点部署将生成 3 套核心协议组合：${plain}\n"

    echo -e "✅ ${bold}${yellow}节点 1【主力旗舰】：${plain}"
    echo -e "   ${bold}VLESS + REALITY + XTLS-Vision${plain}"
    echo -e "   ├─ 协议架构: 应用层 VLESS │ 安全层 REALITY │ 传输层 TCP │ 流控 XTLS-Vision"
    echo -e "   ├─ 端口分配: 端口 443 (TCP)"
    echo -e "   ├─ 核心定位: 【日常主力直连】"
    echo -e "   ├─ 特点属性: 无需域名、免证书、CPU 占用几乎为 0，适合轻量主机，不可套 CDN"
    echo -e "   └─ 调度内核: 客户端调度 ${green}Xray${plain} 内核\n"

    echo -e "✅ ${bold}${yellow}节点 2【弱网救星】：${plain}"
    echo -e "   ${bold}Hysteria 2 (UDP 端口跳跃)${plain}"
    echo -e "   ├─ 协议架构: 应用层 Hysteria 2 │ 传输层 UDP (Brutal) │ 内核 NAT 端口跳跃"
    echo -e "   ├─ 端口分配: 主端口 8443 │ 动态跳跃段 20000:40000 (共 20001 个可用端口)"
    echo -e "   ├─ 核心定位: 【高吞吐强推】"
    echo -e "   ├─ 特点属性: 暴力拥塞控制抗 30%~50% 丢包、动态跳跃突破运营商 UDP QoS，适合晚高峰，不可套 CDN"
    echo -e "   └─ 调度内核: 客户端调度 ${green}sing-box${plain} 内核\n"

    echo -e "✅ ${bold}${yellow}节点 3【容灾防封】：${plain}"
    echo -e "   ${bold}VLESS + XHTTP + TLS (可套CDN+WARP)${plain}"
    echo -e "   ├─ 协议架构: 应用层 VLESS │ 传输层 XHTTP │ 安全层 TLS │ 分流扩展 Cloudflare WARP 出口"
    echo -e "   ├─ 端口分配: 端口 2053 (TCP)"
    echo -e "   ├─ 核心定位: 【容灾防封备用】"
    echo -e "   ├─ 特点属性: 秒救被墙 IP；可直连、可套不死 CDN 实现隐匿 VPS 真实物理 IP"
    echo -e "   └─ 调度内核: 客户端调度 ${green}Xray${plain} 内核\n"

    echo -e "${cyan}============================ 请选择部署模式 ============================${plain}"
    echo -e "  ${green}1.${plain} 小白模式 (回车即可，自动分配端口)"
    echo -e "  ${green}2.${plain} 自定义端口与参数模式"
    echo -e "${cyan}========================================================================${plain}"
    read -rp "请输入模式编号 [默认: 1]: " mode_choice
    mode_choice=${mode_choice:-1}

    if [[ "$mode_choice" == "2" ]]; then
        echo -e "\n${cyan}--- 进入自定义参数配置 ---${plain}"
        while true; do
            read -rp "请输入 REALITY 端口 [默认: 443]: " user_reality_port
            user_reality_port=${user_reality_port:-443}
            if [[ "$user_reality_port" =~ ^[0-9]+$ ]] && [ "$user_reality_port" -ge 1 ] && [ "$user_reality_port" -le 65535 ]; then
                PORT_REALITY=$user_reality_port
                break
            else
                warn "端口范围无效 (1-65535)，请重新输入！"
            fi
        done

        while true; do
            read -rp "请输入 Hysteria 2 主端口 [默认: 8443]: " user_hy2_port
            user_hy2_port=${user_hy2_port:-8443}
            if [[ "$user_hy2_port" =~ ^[0-9]+$ ]] && [ "$user_hy2_port" -ge 1 ] && [ "$user_hy2_port" -le 65535 ]; then
                PORT_HY2=$user_hy2_port
                break
            else
                warn "端口范围无效 (1-65535)，请重新输入！"
            fi
        done

        while true; do
            read -rp "请输入 Hysteria 2 端口跳跃起始端口 [默认: 20000]: " user_hop_start
            user_hop_start=${user_hop_start:-20000}
            read -rp "请输入 Hysteria 2 端口跳跃结束端口 [默认: 40000]: " user_hop_end
            user_hop_end=${user_hop_end:-40000}
            if [[ "$user_hop_start" =~ ^[0-9]+$ && "$user_hop_end" =~ ^[0-9]+$ ]] && \
               [ "$user_hop_start" -ge 1 ] && [ "$user_hop_end" -le 65535 ] && \
               [ "$user_hop_start" -lt "$user_hop_end" ]; then
                PORT_HOP_START=$user_hop_start
                PORT_HOP_END=$user_hop_end
                break
            else
                warn "端口跳跃范围无效 (起始必须小于结束，1-65535)，请重新输入！"
            fi
        done

        while true; do
            read -rp "请输入 VLESS-XHTTP 端口 [默认: 2053]: " user_xhttp_port
            user_xhttp_port=${user_xhttp_port:-2053}
            if [[ "$user_xhttp_port" =~ ^[0-9]+$ ]] && [ "$user_xhttp_port" -ge 1 ] && [ "$user_xhttp_port" -le 65535 ]; then
                PORT_XHTTP=$user_xhttp_port
                break
            else
                warn "端口范围无效 (1-65535)，请重新输入！"
            fi
        done

        read -rp "请输入 REALITY 伪装域名 [回车自动智能探测最优 SNI]: " user_sni
        if [[ -n "$user_sni" ]]; then
            REALITY_SNI="$user_sni"
        else
            probe_best_sni
        fi
    else
        PORT_HOP_START=20000
        PORT_HOP_END=40000

        if check_port_occupied 443 "tcp"; then
            warn "端口 443 已被占用，正在动态寻找可用高位端口..."
            PORT_REALITY=$(find_free_port 10443)
        else
            PORT_REALITY=443
        fi

        if check_port_occupied 8443 "udp"; then
            PORT_HY2=$(find_free_port 18443)
        else
            PORT_HY2=8443
        fi

        if check_port_occupied 2053 "tcp"; then
            PORT_XHTTP=$(find_free_port 12053)
        else
            PORT_XHTTP=2053
        fi

        probe_best_sni
    fi

    echo -e "\n${cyan}========================================================================${plain}"
    info "选定端口: REALITY: ${PORT_REALITY}, Hysteria2: ${PORT_HY2} (跳跃段: ${PORT_HOP_START}-${PORT_HOP_END}), XHTTP: ${PORT_XHTTP}"

    configure_firewalls "${PORT_REALITY}" "${PORT_HY2}" "${PORT_XHTTP}" "${PORT_HOP_START}" "${PORT_HOP_END}"
    install_xray_core
    generate_credentials
    setup_iptables_port_hopping
    generate_server_config
    setup_system_service
    save_env_data

    if [[ -f "$0" && ! "$0" =~ ^/dev/fd/ && ! "$0" =~ ^/proc/ && "$0" != "bash" && "$0" != "-bash" && "$0" != "sh" ]]; then
        cp -f "$0" "${CONFIG_DIR}/tofu.sh" >/dev/null 2>&1
        cp -f "$0" "${TOFU_BIN}" >/dev/null 2>&1
    elif [[ -s "${CONFIG_DIR}/tofu.sh" ]]; then
        cp -f "${CONFIG_DIR}/tofu.sh" "${TOFU_BIN}" >/dev/null 2>&1
    else
        local script_src="https://raw.githubusercontent.com/YGGYDW/ToFu/refs/heads/main/tofu.sh"
        local script_mirror="https://ghproxy.net/${script_src}"
        echo -e "${cyan}[下载]${plain} 正在注册全局快捷命令 tofu..."
        if curl -L --progress-bar --connect-timeout 5 -m 15 "${script_src}" -o "${CONFIG_DIR}/tofu.sh" 2>/dev/null; then
            echo -e "${green}.........................................✅${plain}"
        elif curl -L --progress-bar --connect-timeout 5 -m 15 "${script_mirror}" -o "${CONFIG_DIR}/tofu.sh" 2>/dev/null; then
            echo -e "${green}.........................................✅${plain}"
        elif wget -q -T 10 -O "${CONFIG_DIR}/tofu.sh" "${script_src}" 2>/dev/null; then
            echo -e "${green}.........................................✅${plain}"
        fi
        [[ -s "${CONFIG_DIR}/tofu.sh" ]] && cp -f "${CONFIG_DIR}/tofu.sh" "${TOFU_BIN}" >/dev/null 2>&1
    fi
    chmod +x "${TOFU_BIN}" >/dev/null 2>&1
    chmod +x "${CONFIG_DIR}/tofu.sh" >/dev/null 2>&1

    show_node_info
}

uninstall_all() {
    warn "正在彻底卸载 ToFu 套件及所有相关配置..."
    load_env_data

    if command -v warp-cli >/dev/null 2>&1; then
        warp-cli disconnect >/dev/null 2>&1 || true
    fi

    if [[ -f "${IPTABLES_SCRIPT}" ]]; then
        /bin/bash "${IPTABLES_SCRIPT}" disable "${PORT_HY2}" "${PORT_HOP_START}" "${PORT_HOP_END}" >/dev/null 2>&1
    fi

    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        systemctl stop tofu >/dev/null 2>&1
        systemctl disable tofu >/dev/null 2>&1
        rm -f "${SYSTEMD_FILE}"
        systemctl daemon-reload
    elif command -v rc-service >/dev/null 2>&1 || [[ -f "${OPENRC_FILE}" ]]; then
        rc-service tofu stop >/dev/null 2>&1
        rc-update del tofu default >/dev/null 2>&1
        rm -f "${OPENRC_FILE}"
    fi

    killall -9 xray >/dev/null 2>&1 || true
    rm -f "${XRAY_BIN}"
    rm -rf "${CONFIG_DIR}"
    rm -rf /usr/local/share/xray
    rm -f /usr/local/bin/geoip.dat /usr/local/bin/geosite.dat
    rm -f "${TOFU_BIN}"
    rm -f /usr/local/bin/xray-box
    rm -f ~/tofu.sh ~/xray-box.sh
    rm -f /etc/apt/sources.list.d/cloudflare-warp.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -f /etc/yum.repos.d/cloudflare-warp.repo
    success "ToFu 套件已彻底干净卸载，未残留任何系统垃圾！"
}

start_service() {
    info "正在启动 ToFu 服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        if systemctl start tofu; then
            success "服务已成功启动。"
        else
            error "服务启动失败！请运行 'journalctl -u tofu -n 30' 查看错误日志。"
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service tofu start
        success "服务已成功启动。"
    else
        killall -9 xray >/dev/null 2>&1 || true
        nohup "${XRAY_BIN}" run -config "${CONFIG_FILE}" >/dev/null 2>&1 &
        success "服务已成功启动。"
    fi
}

stop_service() {
    info "正在停止 ToFu 服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        systemctl stop tofu >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service tofu stop >/dev/null 2>&1
    fi
    killall -9 xray >/dev/null 2>&1 || true
    success "ToFu 服务已成功停止。"
}

restart_service() {
    info "正在重启 ToFu 服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        if systemctl restart tofu; then
            success "服务已重启完毕。"
        else
            error "服务重启失败！请运行 'journalctl -u tofu -n 30' 查看错误日志。"
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service tofu restart
        success "服务已重启完毕。"
    else
        killall -9 xray >/dev/null 2>&1 || true
        nohup "${XRAY_BIN}" run -config "${CONFIG_FILE}" >/dev/null 2>&1 &
        success "服务已重启完毕。"
    fi
}

view_logs() {
    info "正在输出最近 50 条实时运行日志 (按 Ctrl+C 退出)..."
    if [[ -d /run/systemd/system ]]; then
        journalctl -u tofu -f -n 50
    else
        error "当前非 systemd 环境，无法直接跟踪日志。"
    fi
}

upgrade_xray_core() {
    info "正在检测 Xray-core 官方最新版本..."
    check_arch
    check_os
    local current_ver
    current_ver=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}')
    local latest_tag
    latest_tag=$(curl -sSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r .tag_name 2>/dev/null)
    if [[ -z "${latest_tag}" || "${latest_tag}" == "null" ]]; then
        error "获取 GitHub 最新版本失败，请检查网络！"
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi
    info "当前版本: ${current_ver:-未知} ➔ 最新版本: ${latest_tag}"
    if [[ "${current_ver}" == "${latest_tag}" || "v${current_ver}" == "${latest_tag}" ]]; then
        success "当前内核已是最新版本 (${current_ver})，无需重复升级！"
        read -rp "是否强制重新拉取覆盖？[y/N]: " force_update
        if [[ "${force_update}" != "y" && "${force_update}" != "Y" ]]; then
            read -n 1 -s -r -p "按任意键返回菜单..."
            return 0
        fi
    fi
    install_xray_core
    restart_service
    success "Xray-core 已成功平滑升级至 ${latest_tag}！"
    read -n 1 -s -r -p "按任意键返回菜单..."
}

get_status_banner() {
    local pid
    pid=$(pgrep -f "${XRAY_BIN}" | head -n 1)
    if [[ -n "$pid" ]]; then
        local mem_kb
        mem_kb=$(grep -i VmRSS /proc/${pid}/status 2>/dev/null | awk '{print $2}')
        local mem_mb="35.0"
        if [[ -n "$mem_kb" ]]; then
            mem_mb=$(awk -v k="$mem_kb" 'BEGIN {printf "%.1f", k/1024}')
        fi
        local cpu_usage
        cpu_usage=$(ps -p "${pid}" -o %cpu --no-headers 2>/dev/null | tr -d ' ' || echo "0.1")
        echo -e "${green}● 正在运行${plain} (进程PID: ${cyan}${pid}${plain} │ 内存占用: ${green}${mem_mb} MB${plain} │ CPU: ${cyan}${cpu_usage}%${plain})"
    else
        echo -e "${red}○ 未运行${plain}"
    fi
}

get_system_info_banner() {
    local xray_ver
    xray_ver=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}')
    local os_pretty=""
    if [[ -f /etc/os-release ]]; then
        os_pretty=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    fi
    [[ -z "$os_pretty" ]] && os_pretty="${OS_TYPE} (${ARCH_NAME})"

    local bbr_str="${yellow}○ 未开启${plain}"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        bbr_str="${green}● 已开启${plain}"
    fi

    echo -e "   本机 IP  : ${cyan}${IP:-检测中}${plain} │ 系统环境: ${yellow}${os_pretty}${plain}"
    echo -e "   核心版本 : ${cyan}Xray-core ${xray_ver:-v26}${plain} │ TCP BBR : ${bbr_str}"
    echo -e "   运行端口 : REALITY: ${green}${PORT_REALITY:-443}${plain} │ Hy2: ${green}${PORT_HY2:-8443}${plain} (${PORT_HOP_START:-20000}:${PORT_HOP_END:-40000}) │ XHTTP: ${green}${PORT_XHTTP:-2053}${plain}"
}

get_cf_egress_status() {
    if [[ -f "${CONFIG_FILE}" ]] && grep -q '"outboundTag": "warp-socks"' "${CONFIG_FILE}" 2>/dev/null; then
        echo -e "${green}● Cloudflare WARP ${plain}"
    else
        echo -e "${yellow}○ 原生 VPS 直连${plain}"
    fi
}

get_cf_egress_banner() {
    if [[ -f "${CONFIG_FILE}" ]] && grep -q '"outboundTag": "warp-socks"' "${CONFIG_FILE}" 2>/dev/null; then
        echo -e "  ${green}╭──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${plain}"
        echo -e "  ${green}│${plain}  ${green}${bold}● Cloudflare WARP 100% 闭环出口${plain} │ ${cyan}目标网站查 IP 100% 显示 Cloudflare  ${plain} ${green}│${plain}"
        echo -e "  ${green}╰──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯${plain}"
    else
        echo -e "  ${yellow}╭─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮${plain}"
        echo -e "  ${yellow}│${plain}  ${yellow}${bold}○ 原生 VPS 直连出口${plain}             │ ${cyan}目标网站查 IP 显示 VPS 真实物理 IP${plain} ${yellow}│${plain}"
        echo -e "  ${yellow}╰─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯${plain}"
    fi
}

toggle_cf_egress() {
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                   🌐 切换节点 3 (CDN) 出口分流模式"
    echo -e "${cyan}========================================================================${plain}"

    local is_cf_on=false
    if grep -q '"outboundTag": "warp-socks"' "${CONFIG_FILE}" 2>/dev/null; then
        is_cf_on=true
    fi

    if [[ "$is_cf_on" == true ]]; then
        echo -e "当前状态: ${green}【● Cloudflare WARP 出口模式】${plain}"
        echo -e "即将切换为: ${yellow}【○ 原生 VPS 直连出口模式】${plain}\n"
        read -rp "确认切换吗？[Y/n]: " confirm_toggle
        if [[ "$confirm_toggle" == "n" || "$confirm_toggle" == "N" ]]; then
            return 0
        fi

        info "正在更新 Xray 路由规则至原生直连..."
        python3 -c '
import json, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    cfg = json.load(f)
for r in cfg.get("routing", {}).get("rules", []):
    if r.get("inboundTag") == ["vless-xhttp"]:
        r["outboundTag"] = "direct"
with open(p, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
' "${CONFIG_FILE}"
        restart_service
        success "已成功切换为【○ 原生 VPS 直连出口模式】！"
        echo -e "✅ 此时通过 CDN 访问网站，出口走 VPS 原生网卡。\n"
        read -n 1 -s -r -p "按任意键返回 Cloudflare CDN+WARP 专区..."
    else
        echo -e "当前状态: ${yellow}【○ 原生 VPS 直连出口模式】${plain}"
        echo -e "即将切换为: ${green}【● 100% Cloudflare WARP 出口模式】${plain}\n"
        read -rp "确认切换吗？[Y/n]: " confirm_toggle
        if [[ "$confirm_toggle" == "n" || "$confirm_toggle" == "N" ]]; then
            return 0
        fi

        if ! command -v warp-cli >/dev/null 2>&1; then
            info "正在初次安装 Cloudflare 官方 WARP 出口组件..."
            if [[ "${PKG_MANAGER}" == "apt-get" ]]; then
                apt-get install -y -q curl gpg >/dev/null 2>&1
                echo -e "${cyan}[下载]${plain} 正在拉取 Cloudflare 认证密钥..."
                curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null && echo -e "${green}.........................................✅${plain}"
                local codename
                codename=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d'=' -f2)
                [[ -z "$codename" ]] && codename="bookworm"
                echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" | tee /etc/apt/sources.list.d/cloudflare-warp.list >/dev/null 2>&1
                apt-get update -y -q >/dev/null 2>&1
                apt-get install -y -q cloudflare-warp >/dev/null 2>&1
            elif [[ "${PKG_MANAGER}" == "yum" ]]; then
                echo -e "${cyan}[下载]${plain} 正在拉取 Cloudflare WARP 仓库配置..."
                curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null 2>&1 && echo -e "${green}.........................................✅${plain}"
                yum install -y cloudflare-warp >/dev/null 2>&1
            fi
        fi

        if command -v warp-cli >/dev/null 2>&1; then
            info "正在初始化本地 WARP 代理网关 (127.0.0.1:40000)..."
            warp-cli --accept-tos register >/dev/null 2>&1 || warp-cli --accept-tos registration new >/dev/null 2>&1 || true
            warp-cli --accept-tos mode proxy >/dev/null 2>&1 || warp-cli --accept-tos set-mode proxy >/dev/null 2>&1 || true
            warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1 || warp-cli --accept-tos set-proxy-port 40000 >/dev/null 2>&1 || true
            warp-cli --accept-tos connect >/dev/null 2>&1 || true
            sleep 2
        else
            error "安装 Cloudflare 官方客户端失败，请检查 VPS 外网连接！"
            read -n 1 -s -r -p "按任意键返回 Cloudflare CDN 专区..."
            return 1
        fi

        info "正在更新 Xray 路由规则至 Cloudflare 出口..."
        python3 -c '
import json, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    cfg = json.load(f)

has_socks = False
for ob in cfg.get("outbounds", []):
    if ob.get("tag") == "warp-socks":
        has_socks = True
        break
if not has_socks:
    cfg.setdefault("outbounds", []).append({
        "tag": "warp-socks",
        "protocol": "socks",
        "settings": {
            "servers": [{"address": "127.0.0.1", "port": 40000}]
        }
    })

for r in cfg.get("routing", {}).get("rules", []):
    if r.get("inboundTag") == ["vless-xhttp"]:
        r["outboundTag"] = "warp-socks"

with open(p, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
' "${CONFIG_FILE}"
        restart_service
        success "已成功切换为【● Cloudflare】出口模式！"
        
        local test_ip
        test_ip=$(curl -s4m4 -x socks5://127.0.0.1:40000 https://api.ipify.org 2>/dev/null || echo "")
        if [[ -n "$test_ip" ]]; then
            success "出口验证成功！Cloudflare WARP 出口 IP: ${test_ip}"
        fi
        echo -e "✅ 此时通过 CDN 访问网站，所有目标网站看到的 IP 100% 为 Cloudflare，真正实现首尾双绝缘！\n"
        read -n 1 -s -r -p "按任意键返回 Cloudflare CDN 专区..."
    fi
}

cloudflare_cdn_menu() {
    local return_target=${1:-"main"}
    while true; do
        clear
        show_logo
        echo -e "${cyan}========================================================================${plain}"
        echo -e "                      ${bold}🌐 Cloudflare CDN 管理专区${plain}                 "
        echo -e "${cyan}========================================================================${plain}"
        echo -e "【当前节点 3 出口状态】:"
        get_cf_egress_banner
        echo -e ""
        echo -e "【出口模式作用与用途解析】:"
        echo -e "  ${bold}├─ 模式 A【○ 原生 VPS 直连出口】${plain} (速度最快 · 日常推荐):"
        echo -e "  │  ▸ 原理: 入口走 CDN 防护，出站由 VPS 物理网卡直连访问目标网站。"
        echo -e "  │  ▸ 优势: 速度极速、延迟最低。"
        echo -e "  │  ▸ 表现: 在网站查 IP，显示【VPS 真实物理 IP】。"
        echo -e "  │"
        echo -e "  ${bold}├─ 模式 B【● Cloudflare  WARP 100% 闭环出口】${plain}:"
        echo -e "  │  ▸ 原理: 入口与出站首尾全走 Cloudflare，VPS 物理真实 IP 全程隐匿。"
        echo -e "  │  ▸ 优势: 100% 隐藏物理机真实 IP；解除被网站屏蔽的 VPS 出站限制。"
        echo -e "  │  ▸ 表现: 在网站查 IP，100% 显示【Cloudflare 官方 IP (x.x.x.x)】。"
        echo -e "  │"
        echo -e "  ${cyan}└─ ✅ 友情提示: 此切换仅对节点 3 生效，节点 1 (REALITY) 与 2 (Hy2) 永远原生直连。${plain}"
        echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        echo -e "  ${green}1.${plain} 为节点3【VLESS + XHTTP + TLS】套 CDN 的方法 (步骤说明)"
        local toggle_label="切换为【● Cloudflare WARP 100% 闭环出口】"
        if [[ -f "${CONFIG_FILE}" ]] && grep -q '"outboundTag": "warp-socks"' "${CONFIG_FILE}" 2>/dev/null; then
            toggle_label="切换为【○ 原生 VPS 直连出口】"
        fi
        echo -e "  ${green}2.${plain} ${toggle_label}"
        echo -e "  ${green}0.${plain} 返回管理菜单"
        echo -e "${cyan}========================================================================${plain}"
        read -rp "请输入操作序号 [0-2]: " cf_choice
        case "$cf_choice" in
            1)
                show_cdn_tutorial "cf_menu"
                ;;
            2)
                toggle_cf_egress
                ;;
            0)
                if [[ "$return_target" == "info" ]]; then
                    show_node_info
                else
                    main_menu
                fi
                return 0
                ;;
            *)
                error "输入错误，请重新选择！"
                sleep 1
                ;;
        esac
    done
}

main_menu() {
    load_env_data
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                         ${bold}ToFu 节点部署 管理菜单${plain}                 "
    echo -e "   服务状态 : $(get_status_banner)"
    get_system_info_banner
    echo -e "${cyan}========================================================================${plain}"
    echo -e "✅ 提示：在终端任意路径输入 ${green}${bold}tofu${plain} 即可随时进入本管理菜单"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo -e "  ${green}1.${plain} 查看所有节点连接信息与二维码"
    echo -e "  ${green}2.${plain} Cloudflare CDN+WARP 专区 [当前出口: $(get_cf_egress_status)]"
    echo -e "  ${green}3.${plain} 重启 ToFu 服务"
    echo -e "  ${green}4.${plain} 停止 ToFu 服务"
    echo -e "  ${green}5.${plain} 查看实时运行日志"
    echo -e "  ${green}6.${plain} 重新安装 / 自定义重置全部配置"
    echo -e "  ${green}7.${plain} 一键升级 Xray-core 至最新正式版"
    echo -e "  ${green}8.${plain} 彻底干净卸载 ToFu 套件"
    echo -e "  ${green}0.${plain} 退出菜单"
    echo -e "${cyan}========================================================================${plain}"
    read -rp "请输入操作序号 [0-8]: " choice
    case "$choice" in
        1) show_node_info ;;
        2) cloudflare_cdn_menu "main" ;;
        3) 
            restart_service
            sleep 1
            main_menu
            ;;
        4) 
            stop_service
            sleep 1
            main_menu
            ;;
        5) view_logs ;;
        6) install_all ;;
        7) 
            upgrade_xray_core
            main_menu
            ;;
        8) uninstall_all ;;
        0) 
            echo -e "\n✅ 感谢使用 ToFu！随时在终端输入 ${green}tofu${plain} 即可再次唤出管理菜单。\n"
            exit 0 
            ;;
        *) error "输入错误，请重新选择！"; sleep 1; main_menu ;;
    esac
}

check_arch
check_os

case "$1" in
    install)        install_all ;;
    uninstall)      uninstall_all ;;
    info)           show_node_info ;;
    restart)        restart_service ;;
    start)          start_service ;;
    stop)           stop_service ;;
    log)            view_logs ;;
    cdn)            cloudflare_cdn_menu "main" ;;
    update|upgrade) upgrade_xray_core ;;
    *)
        if [[ -f "${DATA_FILE}" || -f "/etc/xray-box/node_info.env" ]]; then
            main_menu
        else
            install_all
        fi
        ;;
esac
