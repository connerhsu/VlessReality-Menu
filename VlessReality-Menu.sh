#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality 一键安装管理脚本 (终极回车符杀手版 v2.2)
# ==============================================================================

set -euo pipefail

# --- 全局变量与常量 ---
readonly SCRIPT_VERSION="V-Custom-2.2"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

readonly red='\e[91m'
readonly green='\e[92m'
readonly yellow='\e[93m'
readonly cyan='\e[96m'
readonly magenta='\e[95m'
readonly none='\e[0m'

# --- 辅助函数 ---
error() { echo -e "\n   ${red}[✖] $1${none}\n" >&2; }
info() { echo -e "\n   ${yellow}[!] $1${none}\n"; }
success() { echo -e "\n   ${green}[✔] $1${none}\n"; }

# 检查 root 权限
check_root() {
    if [[ $(id -u) != 0 ]]; then
        error "错误: 必须以 root 用户运行"
        exit 1
    fi
}

# 安装依赖项 (静默)
install_dependencies() {
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null || ! command -v openssl &>/dev/null; then
        apt-get update -y &>/dev/null || true
        apt-get install -y jq curl openssl &>/dev/null || true
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip
    ip=$(curl -s4m8 https://api.ipify.org || curl -s4m8 https://ip.sb)
    if [[ -z "$ip" ]]; then
        echo "127.0.0.1"
    else
        echo "$ip"
    fi
}

# 设置快捷键 (终极解法：使用 tr 暴力剔除 Windows 回车符)
setup_shortcut() {
    local target="/usr/bin/vless"
    local current_file
    
    current_file=$(readlink -f "$0" 2>/dev/null || echo "$0")
    
    if [[ -f "$current_file" && "$current_file" != "$target" ]]; then
        # 暴力过滤所有 \r 字符，彻底解决 bad interpreter 报错
        cat "$current_file" | tr -d '\r' > "$target"
        chmod +x "$target"
        # 刷新 bash 缓存
        hash -r 2>/dev/null || true
    fi
}

# 每次运行后台更新 (容错处理)
auto_update_xray() {
    if [[ -f "$xray_binary_path" ]]; then
        bash -c "$(curl -sL $xray_install_script_url)" @ install &> /dev/null || true
        systemctl restart xray &> /dev/null || true
    fi
}

# 获取内存信息
get_mem_info() {
    free -m | awk 'NR==2{printf "%sMB / %sMB (%.2f%%)", $3,$2,$3*100/$2}' || echo "获取失败"
}

# 获取当前配置信息
get_current_config() {
    if [[ -f "$xray_config_path" ]]; then
        CURRENT_PORT=$(jq -r '.inbounds[0].port' "$xray_config_path" 2>/dev/null || echo "未配置")
        CURRENT_UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path" 2>/dev/null || echo "未配置")
        CURRENT_DOMAIN=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path" 2>/dev/null || echo "未配置")
        CURRENT_SHORTID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$xray_config_path" 2>/dev/null || echo "未配置")
    else
        CURRENT_PORT="未安装"
        CURRENT_UUID="未安装"
        CURRENT_DOMAIN="未安装"
        CURRENT_SHORTID="未安装"
    fi
}

# 写入 Xray 配置文件
write_config() {
    local port=$1 uuid=$2 domain=$3 private_key=$4 public_key=$5 shortid=$6
    mkdir -p /usr/local/etc/xray

    jq -n \
    --argjson port "$port" \
    --arg uuid "$uuid" \
    --arg domain "$domain" \
    --arg private_key "$private_key" \
    --arg public_key "$public_key" \
    --arg shortid "$shortid" \
    '{
      "log": {"loglevel": "warning"},
      "inbounds": [{
        "listen": "0.0.0.0",
        "port": $port,
        "protocol": "vless",
        "settings": {
          "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
          "decryption": "none"
        },
        "streamSettings": {
          "network": "tcp",
          "security": "reality",
          "realitySettings": {
            "show": false,
            "dest": ($domain + ":443"),
            "xver": 0,
            "serverNames": [$domain],
            "privateKey": $private_key,
            "publicKey": $public_key,
            "shortIds": [$shortid]
          }
        },
        "sniffing": {
          "enabled": true,
          "destOverride": ["http", "tls", "quic"]
        }
      }],
      "outbounds": [{
        "protocol": "freedom",
        "settings": {
          "domainStrategy": "UseIPv4v6"
        }
      }]
    }' > "$xray_config_path"
}

# 安装 Xray 及配置
install_xray() {
    echo ""
    info "正在后台静默安装核心，请稍候..."
    bash -c "$(curl -sL $xray_install_script_url)" @ install &> /dev/null || true
    
    if [[ ! -f "$xray_binary_path" ]]; then
        error "核心安装失败，请检查网络！"
        return 1
    fi
    success "核心就绪！"

    read -p "   请输入端口 [1-65535] (默认: 8443): " port
    port=${port:-8443}

    read -p "   请输入SNI域名 (默认: aod.itunes.apple.com): " domain
    domain=${domain:-"aod.itunes.apple.com"}

    local uuid
    uuid=$("$xray_binary_path" uuid || true)
    [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
    info "UUID: ${cyan}${uuid}${none}"

    local shortid
    shortid=$(openssl rand -hex 8)
    info "ShortID: ${cyan}${shortid}${none}"

    info "正在生成 Reality 密钥对..."
    local key_pair
    key_pair=$("$xray_binary_path" x25519 2>&1 || true)
    
    local private_key
    local public_key
    private_key=$(echo "$key_pair" | grep -iE "Private" | awk '{print $NF}')
    public_key=$(echo "$key_pair" | grep -iE "Public|Password" | awk '{print $NF}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "密钥对生成失败！Xray 输出信息: $key_pair"
        return 1
    fi

    write_config "$port" "$uuid" "$domain" "$private_key" "$public_key" "$shortid"
    
    systemctl restart xray || true
    systemctl enable xray &> /dev/null || true
    success "节点配置成功！"
    
    view_subscription_info
}

# 查看订阅信息
view_subscription_info() {
    if [[ ! -f "$xray_config_path" ]]; then 
        error "未找到配置，请先执行安装选项。"
        return
    fi

    local ip=$(get_public_ip)
    local port=$(jq -r '.inbounds[0].port' "$xray_config_path" || echo "8443")
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path" || echo "")
    local domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path" || echo "")
    local public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path" || echo "")
    local shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$xray_config_path" || echo "")

    local link_name="Xray-Reality | $(hostname)"
    local vless_url="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name}"

local mihomo_yaml="proxies:
  - name: \"${link_name}\"
    type: vless
    server: ${ip}
    port: ${port}
    uuid: \"${uuid}\"
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: \"${domain}\"
    client-fingerprint: chrome
    reality-opts:
      public-key: \"${public_key}\"
      short-id: \"${shortid}\""

    echo -e ""
    echo -e "${cyan}   ==========================================================${none}"
    echo -e "   ${green}✨ 节点配置信息${none}"
    echo -e "${cyan}   ==========================================================${none}"
    echo -e "   ${yellow}▶ 地址 (IP)  :${none} ${cyan}$ip${none}"
    echo -e "   ${yellow}▶ 端口 (Port):${none} ${cyan}$port${none}"
    echo -e "   ${yellow}▶ UUID       :${none} ${cyan}$uuid${none}"
    echo -e "   ${yellow}▶ 伪装 (SNI) :${none} ${cyan}$domain${none}"
    echo -e "   ${yellow}▶ 公钥 (PBK) :${none} ${cyan}$public_key${none}"
    echo -e "   ${yellow}▶ ShortId    :${none} ${cyan}$shortid${none}"
    echo -e ""
    echo -e "   ${magenta}🔗 URL 直链 (点击复制):${none}"
    echo -e "   ${cyan}${vless_url}${none}"
    echo -e ""
    echo -e "   ${magenta}🐈 Mihomo (Clash Meta) YAML 格式:${none}"
    echo "$mihomo_yaml"
    echo -e "${cyan}   ==========================================================${none}"
    echo -e ""
}

# 常规卸载
uninstall_xray_keep_conf() {
    read -p "   确定卸载 Xray 核心 (保留配置文件)？[Y/n]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then return; fi
    bash -c "$(curl -sL $xray_install_script_url)" @ remove &> /dev/null || true
    success "Xray 核心已卸载，您的节点配置文件已安全保留。"
}

# 彻底卸载
uninstall_xray_completely() {
    read -p "   警告: 确定要彻底卸载 Xray 并删除所有节点配置和日志吗？[Y/n]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then return; fi
    info "正在后台彻底清理所有数据..."
    bash -c "$(curl -sL $xray_install_script_url)" @ remove --purge &> /dev/null || true
    
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    rm -rf /var/log/xray
    rm -f /usr/bin/vless
    
    success "Xray 及所有数据已彻底清理干净！"
}

# 主菜单UI
main_menu() {
    while true; do
        get_current_config
        local mem_info=$(get_mem_info)
        local service_status="${red}未运行 🔴${none}"
        if systemctl is-active --quiet xray 2>/dev/null; then service_status="${green}运行中 🟢${none}"; fi

        clear
        echo -e ""
        echo -e "${cyan}   ==========================================================${none}"
        echo -e "   🚀 ${green}Xray VLESS-Reality 极简管理面板${none} ${yellow}[v2.2]${none} | 快捷键: ${green}vless${none}"
        echo -e "${cyan}   ==========================================================${none}"
        echo -e ""
        echo -e "   ${magenta}■ 服务器状态${none}"
        echo -e "   ----------------------------------------------------------"
        echo -e "   运行状态 : ${service_status}"
        echo -e "   内存占用 : ${cyan}${mem_info}${none}"
        echo -e ""
        echo -e "   ${magenta}■ 节点配置卡${none}"
        echo -e "   ----------------------------------------------------------"
        echo -e "   监听端口 : ${green}${CURRENT_PORT}${none}"
        echo -e "   伪装 SNI : ${green}${CURRENT_DOMAIN}${none}"
        echo -e "   ShortId  : ${green}${CURRENT_SHORTID}${none}"
        echo -e ""
        echo -e "${cyan}   ==========================================================${none}"
        echo -e "   ${green}[1]${none} 🚀  安装 / 重装 Xray"
        echo -e "   ${green}[2]${none} 🔗  查看节点配置 (分享 URL / Mihomo 格式)"
        echo -e "   ${yellow}[3]${none} 🔄  重启 Xray 服务"
        echo -e "   ${magenta}[4]${none} 🧹  常规卸载 (保留配置)"
        echo -e "   ${red}[5]${none} 🗑️   彻底卸载 (清除所有数据)"
        echo -e "   ${green}[0]${none} ❌  退出面板"
        echo -e "${cyan}   ==========================================================${none}"
        echo -e ""
        
        read -p "   请选择执行操作 [0-5]: " choice
        case $choice in
            1) install_xray ;;
            2) view_subscription_info ;;
            3) systemctl restart xray && success "服务已成功重启" ;;
            4) uninstall_xray_keep_conf ;;
            5) uninstall_xray_completely ;;
            0) echo -e "\n   ${green}感谢使用，已退出！${none}\n"; exit 0 ;;
            *) error "无效选项，请输入对应数字" ;;
        esac
        
        read -n 1 -s -r -p "   按任意键返回主菜单..."
    done
}

# 脚本入口
main() {
    check_root
    install_dependencies
    setup_shortcut
    auto_update_xray
    main_menu
}

main "$@"
