#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality 一键安装管理脚本
# ==============================================================================

set -euo pipefail

# --- 全局变量与常量 ---
readonly SCRIPT_VERSION="V-Custom-1.1"
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
error() { echo -e "\n${red}[✖] $1${none}\n" >&2; }
info() { echo -e "\n${yellow}[!] $1${none}\n"; }
success() { echo -e "\n${green}[✔] $1${none}\n"; }

# 检查 root 权限
check_root() {
    if [[ $(id -u) != 0 ]]; then
        error "错误: 您必须以 root 用户身份运行此脚本"
        exit 1
    fi
}

# 安装依赖项
install_dependencies() {
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null || ! command -v openssl &>/dev/null; then
        info "正在安装必要的依赖 (jq, curl, openssl)，请稍候..."
        apt-get update -y &>/dev/null || true
        apt-get install -y jq curl openssl &>/dev/null
    fi
}

# 获取公网 IP
get_public_ip() {
    local ip
    ip=$(curl -s4m8 https://api.ipify.org || curl -s4m8 https://ip.sb)
    if [[ -z "$ip" ]]; then
        error "无法获取公网 IP 地址。"
        return 1
    fi
    echo "$ip"
}

# 设置快捷键
setup_shortcut() {
    local script_path
    script_path=$(readlink -f "$0")
    if [[ ! -f "/usr/bin/vless" || $(cat "/usr/bin/vless" | grep -c "$script_path") -eq 0 ]]; then
        echo -e "#!/bin/bash\nbash $script_path \$@" > /usr/bin/vless
        chmod +x /usr/bin/vless
    fi
}

# 获取内存信息
get_mem_info() {
    local mem_info
    mem_info=$(free -m | awk 'NR==2{printf "%sMB / %sMB (%.2f%%)", $3,$2,$3*100/$2}')
    echo "$mem_info"
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
    local port=$1
    local uuid=$2
    local domain=$3
    local private_key=$4
    local public_key=$5
    local shortid=$6

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
    info "正在后台下载并安装 Xray 核心，请耐心等待..."

    # 1. 下载核心 (静默模式，屏蔽输出)
    bash -c "$(curl -sL $xray_install_script_url)" @ install &> /dev/null
    
    if [[ ! -f "$xray_binary_path" ]]; then
        error "Xray 核心安装失败！请检查服务器网络。"
        return 1
    fi
    success "Xray 核心安装完成！"

    # 2. 收集参数
    read -p "$(echo -e "请输入端口 [1-65535] (默认: ${cyan}8443${none}): ")" port
    port=${port:-8443}

    read -p "$(echo -e "请输入SNI域名 (默认: ${cyan}aod.itunes.apple.com${none}): ")" domain
    domain=${domain:-"aod.itunes.apple.com"}

    local uuid
    uuid=$($xray_binary_path uuid) # 改用 xray 官方命令生成更规范的 UUID
    info "已自动生成 UUID: ${cyan}${uuid}${none}"

    local shortid
    shortid=$(openssl rand -hex 8)
    info "已自动生成 ShortID: ${cyan}${shortid}${none}"

    # 3. 生成 Reality 密钥对 (增强兼容性提取逻辑)
    info "正在生成 Reality 密钥对..."
    local key_pair
    key_pair=$($xray_binary_path x25519 2>/dev/null)
    
    local private_key
    local public_key
    # 使用 awk 分割并剔除可能存在的空格
    private_key=$(echo "$key_pair" | grep -i "Private" | awk -F ':' '{print $2}' | tr -d ' \r\n')
    public_key=$(echo "$key_pair" | grep -i "Public" | awk -F ':' '{print $2}' | tr -d ' \r\n')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！获取到的输出为空。"
        return 1
    fi

    # 4. 写入配置并重启
    write_config "$port" "$uuid" "$domain" "$private_key" "$public_key" "$shortid"
    
    systemctl restart xray
    systemctl enable xray
    success "Xray VLESS-Reality 安装并配置成功！"
    
    view_subscription_info
}

# 查看订阅信息
view_subscription_info() {
    if [[ ! -f "$xray_config_path" ]]; then 
        error "错误: 配置文件不存在, 请先安装。"
        return
    fi

    local ip=$(get_public_ip)
    local port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    local public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path")
    local shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$xray_config_path")

    local link_name="Xray-Reality-$(hostname)"
    local vless_url="vless://${uuid}@${ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name}"

    echo -e "\n${green}================ Xray 节点信息 ================${none}"
    echo -e "${yellow} 地址 (IP) :${none} ${cyan}$ip${none}"
    echo -e "${yellow} 端口 (Port):${none} ${cyan}$port${none}"
    echo -e "${yellow} UUID      :${none} ${cyan}$uuid${none}"
    echo -e "${yellow} 伪装 (SNI) :${none} ${cyan}$domain${none}"
    echo -e "${yellow} 公钥 (PBK) :${none} ${cyan}$public_key${none}"
    echo -e "${yellow} ShortId   :${none} ${cyan}$shortid${none}"
    echo -e "${green}===============================================${none}"
    echo -e "${yellow} 分享链接 (VLESS):${none}"
    echo -e "${cyan}${vless_url}${none}\n"
}

# 卸载 Xray
uninstall_xray() {
    read -p "您确定要卸载 Xray 吗？这将删除所有相关文件。[Y/n]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "卸载操作已取消。"
        return
    fi
    info "正在后台卸载 Xray..."
    bash -c "$(curl -sL $xray_install_script_url)" @ remove --purge &> /dev/null
    rm -f /usr/bin/vless
    success "Xray 已成功卸载。"
}

# 主菜单
main_menu() {
    while true; do
        get_current_config
        local mem_info=$(get_mem_info)
        local service_status="${red}未运行${none}"
        if systemctl is-active --quiet xray 2>/dev/null; then service_status="${green}运行中${none}"; fi

        clear
        echo -e "${cyan}======================================================${none}"
        echo -e " ${green}Xray VLESS-Reality 一键管理面板${none} | 快捷键: ${cyan}vless${none}"
        echo -e "${cyan}======================================================${none}"
        echo -e " 内存占用 : ${yellow}${mem_info}${none}"
        echo -e " 运行状态 : ${service_status}"
        echo -e " 当前端口 : ${cyan}${CURRENT_PORT}${none}"
        echo -e " 伪装 SNI : ${cyan}${CURRENT_DOMAIN}${none}"
        echo -e " ShortId  : ${cyan}${CURRENT_SHORTID}${none}"
        echo -e "${cyan}======================================================${none}"
        echo -e " ${green}1.${none} 安装/重装 Xray (VLESS-Reality)"
        echo -e " ${cyan}2.${none} 查看节点订阅信息"
        echo -e " ${yellow}3.${none} 重启 Xray 服务"
        echo -e " ${magenta}4.${none} 查看 Xray 运行日志"
        echo -e " ${red}5.${none} 卸载 Xray"
        echo -e " ${green}0.${none} 退出脚本"
        echo -e "${cyan}======================================================${none}"
        
        read -p "请输入选项 [0-5]: " choice
        case $choice in
            1) install_xray ;;
            2) view_subscription_info ;;
            3) systemctl restart xray && success "Xray 重启成功！" ;;
            4) journalctl -u xray -f --no-pager ;;
            5) uninstall_xray ;;
            0) exit 0 ;;
            *) error "无效选项，请输入 0-5 之间的数字。" ;;
        esac
        
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# 脚本入口点
main() {
    check_root
    install_dependencies
    setup_shortcut
    main_menu
}

main "$@"
