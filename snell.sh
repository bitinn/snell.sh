#!/bin/bash
# =========================================
# 作者: jinqian
# 日期: 2024年9月
# 网站：jinqians.com
# 描述: 这个脚本用于安装、卸载、查看和更新 Snell 代理
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

#当前版本号
current_version="1.3"

SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
INSTALL_DIR="/usr/local/bin"
SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
SNELL_VERSION="v4.1.1"  # 初始默认版本

# 等待其他 apt 进程完成
wait_for_apt() {
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo -e "${YELLOW}Waiting for apt progress...${RESET}"
        sleep 1
    done
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}Please run script with root user.${RESET}"
        exit 1
    fi
}
check_root

# 检查 jq 是否安装
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}Package jq not yet installed, installing...${RESET}"
        # 根据系统类型安装 jq
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y jq
        elif [ -x "$(command -v yum)" ]; then
            yum install -y jq
        else
            echo -e "${RED}Unsupported package manager, please install jq manually${RESET}"
            exit 1
        fi
    fi
}
check_jq

# 检查 Snell 是否已安装
check_snell_installed() {
    if command -v snell-server &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 获取 Snell 最新版本
get_latest_snell_version() {
    latest_version=$(curl -s https://manual.nssurge.com/others/snell.html | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    if [ -n "$latest_version" ]; then
        SNELL_VERSION="v${latest_version}"
    else
        echo -e "${RED}Unable to obtain latest Snell server, using latest version instead: ${SNELL_VERSION}${RESET}"
    fi
}

# 比较版本号
version_greater_equal() {
    # 拆分版本号
    local ver1="$1"
    local ver2="$2"

    # 去除 'v' 前缀
    ver1=${ver1#v}
    ver2=${ver2#v}

    # 将版本号用 '.' 分割
    IFS='.' read -r -a ver1_arr <<< "$ver1"
    IFS='.' read -r -a ver2_arr <<< "$ver2"

    # 比较主版本、次版本和修订版本
    for i in {0..2}; do
        if (( ver1_arr[i] > ver2_arr[i] )); then
            return 0
        elif (( ver1_arr[i] < ver2_arr[i] )); then
            return 1
        fi
    done
    return 0
}

# 用户输入端口号，范围 1-65535
get_user_port() {
    while true; do
        read -rp "Please select a port (1-65535): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            echo -e "${GREEN}Port: $PORT${RESET}"
            break
        else
            echo -e "${RED}Invalid port number, please pick between 1 and 65535。${RESET}"
        fi
    done
}

# 开放端口 (ufw 和 iptables)
open_port() {
    local PORT=$1
    # 检查 ufw 是否已安装
    if command -v ufw &> /dev/null; then
        echo -e "${CYAN}Opening port in UFW: $PORT${RESET}"
        ufw allow "$PORT"/tcp
    fi

    # 检查 iptables 是否已安装
    if command -v iptables &> /dev/null; then
        echo -e "${CYAN}Opening port in iptables: $PORT${RESET}"
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        iptables-save > /etc/iptables/rules.v4
    fi
}

# 安装 Snell
install_snell() {
    echo -e "${CYAN}Installing Snell${RESET}"

    wait_for_apt
    apt update && apt install -y wget unzip

    get_latest_snell_version
    ARCH=$(uname -m)
    SNELL_URL=""
    
    if [[ ${ARCH} == "aarch64" ]]; then
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-aarch64.zip"
    else
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-amd64.zip"
    fi

    wget ${SNELL_URL} -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo -e "${RED}Snell server download failed${RESET}"
        exit 1
    fi

    unzip -o snell-server.zip -d ${INSTALL_DIR}
    if [ $? -ne 0 ]; then
        echo -e "${RED}Snell server unzip failed${RESET}"
        exit 1
    fi

    rm snell-server.zip
    chmod +x ${INSTALL_DIR}/snell-server

    get_user_port  # 获取用户输入的端口
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    mkdir -p ${SNELL_CONF_DIR}

    cat > ${SNELL_CONF_FILE} << EOF
[snell-server]
listen = ::0:${PORT}
psk = ${RANDOM_PSK}
ipv6 = true
EOF

    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if [ $? -ne 0 ]; then
        echo -e "${RED}Reloading systemd config failed${RESET}"
        exit 1
    fi

    systemctl enable snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}Unable to enable Snell services${RESET}"
        exit 1
    fi

    systemctl start snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}Unable to start Snell services${RESET}"
        exit 1
    fi

    # 开放端口
    open_port "$PORT"

    HOST_IP=$(curl -s http://checkip.amazonaws.com)
    IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)

    echo -e "${GREEN}Snell installed!${RESET}"
    echo "${IP_COUNTRY} = snell, ${HOST_IP}, ${PORT}, psk = ${RANDOM_PSK}, version = 4, reuse = true, tfo = true"
}

# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}Uninstalling Snell${RESET}"

    systemctl stop snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}Unable to stop Snell services${RESET}"
        exit 1
    fi

    systemctl disable snell
    if [ $? -ne 0 ]; then
        echo -e "${RED}Unable to disable Snell services${RESET}"
        exit 1
    fi

    rm /lib/systemd/system/snell.service
    if [ $? -ne 0 ];then
        echo -e "${RED}Unable to remove systemd config${RESET}"
        exit 1
    fi

    rm /usr/local/bin/snell-server
    rm -rf ${SNELL_CONF_DIR}

    echo -e "${GREEN}Snell uninstalled!${RESET}"
}

view_snell_config() {
    if [ -f "${SNELL_CONF_FILE}" ]; then
        echo -e "${GREEN}Current Snell server config:${RESET}"
        cat "${SNELL_CONF_FILE}"
        
        # 解析配置文件中的信息
        HOST_IP=$(curl -s http://checkip.amazonaws.com)
        IP_COUNTRY=$(curl -s http://ipinfo.io/${HOST_IP}/country)
        
        # 提取端口号 - 提取 "::0:" 后面的部分
        PORT=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        
        # 提取 PSK
        PSK=$(grep -E '^psk' "${SNELL_CONF_FILE}" | awk -F'=' '{print $2}' | tr -d ' ')
        
        echo -e "${GREEN}Network Stats:${RESET}"
        echo "Public IP: ${HOST_IP}"
        echo "Country (Guessed): ${IP_COUNTRY}"
        echo "Port: ${PORT}"
        echo "PSK: ${PSK}"
        
        # 检查端口号和 PSK 是否正确提取
        if [ -z "${PORT}" ]; then
            echo -e "${RED}Port config not available${RESET}"
        fi
        
        if [ -z "${PSK}" ]; then
            echo -e "${RED}PSK config not available${RESET}"
        fi
        
        echo -e "${GREEN}${IP_COUNTRY} = snell, ${HOST_IP}, ${PORT}, psk = ${PSK}, version = 4, reuse = true, tfo = true${RESET}"
        
        # 等待用户按任意键返回主菜单
        read -p "Press any key to return ..."
    else
        echo -e "${RED}Snell config missing${RESET}"
    fi
}


# 获取当前安装的 Snell 版本
get_current_snell_version() {
    CURRENT_VERSION=$(snell-server --v 2>&1 | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+')
    if [ -z "$CURRENT_VERSION" ]; then
        echo -e "${RED}Unable to extract Snell version${RESET}"
        exit 1
    fi
}

# 检查 Snell 更新
check_snell_update() {
    get_latest_snell_version
    get_current_snell_version

    if ! version_greater_equal "$CURRENT_VERSION" "$SNELL_VERSION"; then
        echo -e "${YELLOW}Current Snell version: ${CURRENT_VERSION}，Latest Snell release: ${SNELL_VERSION}${RESET}"
        echo -e "${CYAN}Upgrade Snell? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            install_snell
        else
            echo -e "${CYAN}Upgrade cancelled${RESET}"
        fi
    else
        echo -e "${GREEN}Using latest Snell release already (${CURRENT_VERSION})${RESET}"
    fi
}

# 获取最新 GitHub 版本
get_latest_github_version() {
    GITHUB_VERSION_INFO=$(curl -s https://api.github.com/repos/bitinn/snell.sh/releases/latest)
    if [ $? -ne 0 ]; then
        echo -e "${RED}Unable to retrieve GitHub api response${RESET}"
        exit 1
    fi

    GITHUB_VERSION=$(echo "$GITHUB_VERSION_INFO" | jq -r '.name' | awk '{print $NF}')
    if [ -z "$GITHUB_VERSION" ]; then
        echo -e "${RED}Unable to extract latest script from GitHub response${RESET}"
        exit 1
    fi
}

# 更新脚本
update_script() {
    get_latest_github_version

    if version_greater_equal "$CURRENT_VERSION" "$GITHUB_VERSION"; then
        echo -e "${GREEN}Already using latest install script (${CURRENT_VERSION})${RESET}"
    else
        # 使用 curl 下载脚本并覆盖当前脚本
        curl -s -o "$0" "https://raw.githubusercontent.com/bitinn/snell.sh/main/snell.sh"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Script updated to latest version: ${GITHUB_VERSION}${RESET}"
            echo -e "${YELLOW}Please rerun this command${RESET}"
            exec "$0"  # 重新执行当前脚本
        else
            echo -e "${RED}Script update failed${RESET}"
        fi
    fi
}

# 主菜单
while true; do
    echo -e "${RED} ========================================= ${RESET}"
    echo -e "${RED} Author - jinqian ${RESET}"
    echo -e "${RED} Source - https://github.com/jinqians/snell.sh ${RESET}"
    echo -e "${RED} Forked - https://github.com/bitinn/snell.sh ${RESET}"
    echo -e "${RED} ========================================= ${RESET}"


    echo -e "${CYAN} ============== Snell Script ============== ${RESET}"
    echo "1) Install Snell"
    echo "2) Uninstall Snell"
    echo "3) View Snell config"
    echo "4) Upgrade Snell server"
    echo "5) Update this script"
    echo "0) Exit"
    read -rp "Please select an option: " choice

    case "$choice" in
        1)
            install_snell
            ;;
        2)
            uninstall_snell
            ;;
        3)
            view_snell_config
            ;;
        4)
            check_snell_update
            ;;
        5)
            update_script
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${RESET}"
            ;;
    esac
done
