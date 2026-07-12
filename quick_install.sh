#!/bin/bash

# Mihomo Linux 一键安装脚本 v2.2.3
# 支持多架构、多系统、智能下载、资源配置管理、覆盖安装
# 项目地址: https://github.com/ForLoveIcu/mihomo-for-linux-install

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 加载资源配置
load_config() {
    # 内置基本配置（作为备用）
    MIHOMO_VERSION="v1.19.12"
    WEBUI_VERSION="v1.19.12"

    # 架构文件映射 - 使用正确的文件名
    declare -gA ARCH_FILES=(
        ["x86_64"]="mihomo-linux-amd64-compatible-v1.19.12.gz"
        ["aarch64"]="mihomo-linux-arm64-v1.19.12.gz"
        ["arm64"]="mihomo-linux-arm64-v1.19.12.gz"
        ["armv7l"]="mihomo-linux-armv7-v1.19.12.gz"
    )

    # 下载地址
    MIHOMO_BASE_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12"
    WEBUI_DOWNLOAD_URL="https://github.com/MetaCubeX/metacubexd/releases/download/v1.189.0/compressed-dist.tgz"

    log_info "已加载内置资源配置 (Mihomo $MIHOMO_VERSION)"
}

# 检测系统架构并返回对应的下载文件名
detect_arch() {
    local arch=$(uname -m)

    # 使用 ARCH_FILES 数组获取对应的文件名
    if [[ -n "${ARCH_FILES[$arch]}" ]]; then
        echo "${ARCH_FILES[$arch]}"
    else
        log_error "不支持的架构: $arch"
        log_error "支持的架构: ${!ARCH_FILES[*]}"
        exit 1
    fi
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo $ID
    else
        log_error "无法检测操作系统"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    local os=$(detect_os)
    log_info "安装必要依赖..."
    
    case $os in
        ubuntu|debian)
            apt-get update
            apt-get install -y curl wget unzip file
            ;;
        centos|rhel|rocky)
            yum install -y curl wget unzip file
            ;;
        *)
            log_warn "未知系统，跳过依赖安装。请确保已安装 curl, wget, unzip, file"
            ;;
    esac
}

# GitHub 加速镜像列表。
#
# 每个条目使用 {url} 作为完整原始 GitHub HTTPS URL 的占位符。例如：
#   https://gh-proxy.com/{url}
#
# 可以通过环境变量覆盖默认列表（逗号分隔）。原始 GitHub 地址始终会作为
# 最后一个回退来源，例如：
#   GITHUB_MIRRORS='https://example-proxy/{url},https://another-proxy/{url}' bash quick_install.sh
get_github_mirrors() {
    local configured_mirror

    if [ -n "${GITHUB_MIRRORS:-}" ]; then
        while IFS= read -r configured_mirror; do
            [ -n "$configured_mirror" ] && printf '%s\n' "$configured_mirror"
        done < <(printf '%s' "$GITHUB_MIRRORS" | tr ',' '\n')
        return 0
    fi

    cat <<'EOF'
https://gh-proxy.com/{url}
https://ghproxy.net/{url}
https://ghproxy.homeboyc.cn/{url}
https://github.akams.cn/{url}
https://ghp.ci/{url}
https://github.moeyy.xyz/{url}
http://toolwa.com/github/{url}
EOF
}

# 根据镜像模板生成下载 URL。兼容旧式前缀配置，但推荐使用 {url} 模板，
# 以避免将 https://github.com/... 拼接为错误路径。
build_download_url() {
    local template=$1
    local original_url=$2

    case "$template" in
        ""|direct|"{url}")
            printf '%s\n' "$original_url"
            ;;
        *"{url}"*)
            printf '%s\n' "${template//\{url\}/$original_url}"
            ;;
        *)
            printf '%s/%s\n' "${template%/}" "$original_url"
            ;;
    esac
}

get_file_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

# 验证下载结果，防止镜像返回 HTML 错误页、截断文件或无效压缩包。
validate_download() {
    local candidate=$1
    local target_path=$2
    local minimum_size=${MIN_FILE_SIZE:-1024}
    local file_size
    local file_type=""

    if [ ! -f "$candidate" ]; then
        log_warn "下载结果不存在"
        return 1
    fi

    file_size=$(get_file_size "$candidate")
    if [ "$file_size" -lt "$minimum_size" ]; then
        log_warn "下载文件太小 (${file_size} bytes)"
        return 1
    fi

    if command -v file >/dev/null 2>&1; then
        file_type=$(file -b -- "$candidate" 2>/dev/null || true)
        if printf '%s\n' "$file_type" | grep -Eqi 'HTML|XML'; then
            log_warn "下载结果是错误页面 ($file_type)"
            return 1
        fi

        case "$target_path" in
            *.sh)
                ;;
            *)
                if printf '%s\n' "$file_type" | grep -Eqi 'text'; then
                    log_warn "下载结果不是预期的二进制或压缩包 ($file_type)"
                    return 1
                fi
                ;;
        esac
    fi

    case "$target_path" in
        *.tgz|*.tar.gz)
            if ! tar -tzf "$candidate" >/dev/null 2>&1; then
                log_warn "下载的 tar.gz 文件无法解压验证"
                return 1
            fi
            ;;
        *.gz)
            if ! gzip -t "$candidate" >/dev/null 2>&1; then
                log_warn "下载的 gzip 文件已损坏或不完整"
                return 1
            fi
            ;;
        *.zip)
            if ! unzip -tqq "$candidate" >/dev/null 2>&1; then
                log_warn "下载的 zip 文件已损坏或不完整"
                return 1
            fi
            ;;
        *.sh)
            if ! head -n 1 "$candidate" | grep -q '^#!'; then
                log_warn "下载的脚本缺少 shebang，已拒绝使用"
                return 1
            fi
            ;;
    esac

    return 0
}

# 智能下载文件 - 支持多镜像、原始 GitHub 回退和文件完整性校验。
download_file() {
    local original_url=$1
    local output=$2
    local max_attempts=${MAX_RETRY_ATTEMPTS:-2}
    local -a sources=()
    local mirror
    local source
    local known_source
    local download_url
    local temp_output
    local file_size

    while IFS= read -r mirror; do
        [ -z "$mirror" ] && continue
        if [ "$mirror" = "direct" ]; then
            mirror="{url}"
        fi

        local duplicate=false
        for known_source in "${sources[@]}"; do
            if [ "$known_source" = "$mirror" ]; then
                duplicate=true
                break
            fi
        done
        if [ "$duplicate" = false ]; then
            sources+=("$mirror")
        fi
    done < <(get_github_mirrors)

    # 始终保留官方 GitHub 直连作为最后回退。
    local has_direct=false
    for known_source in "${sources[@]}"; do
        if [ "$known_source" = "{url}" ]; then
            has_direct=true
            break
        fi
    done
    if [ "$has_direct" = false ]; then
        sources+=("{url}")
    fi

    if ! temp_output=$(mktemp "${output}.part.XXXXXX"); then
        log_error "无法创建临时下载文件: $output"
        return 1
    fi

    for source in "${sources[@]}"; do
        download_url=$(build_download_url "$source" "$original_url")
        if [ "$source" = "{url}" ]; then
            log_info "尝试官方 GitHub 地址下载"
        else
            log_info "尝试 GitHub 加速地址: $source"
        fi

        for ((i = 1; i <= max_attempts; i++)); do
            log_info "下载尝试 ($i/$max_attempts): $(basename "$output")"
            # -C - 断点续传；超时后保留 .part 以便同镜像重试续传
            if curl -fL -C - --retry 2 --retry-delay 2 --connect-timeout "${CONNECT_TIMEOUT:-30}" \
                --max-time "${DOWNLOAD_TIMEOUT:-600}" --silent --show-error \
                --user-agent "mihomo-for-linux-install/2.2.3" -o "$temp_output" "$download_url"; then
                if validate_download "$temp_output" "$output"; then
                    file_size=$(get_file_size "$temp_output")
                    mv -f "$temp_output" "$output"
                    log_success "下载成功: $output (${file_size} bytes)"
                    return 0
                fi
                # 同一个镜像已经返回错误内容，直接切换下一个来源。
                rm -f "$temp_output"
                break
            fi
            log_warn "下载失败，重试中（支持断点续传）..."
            sleep "${DOWNLOAD_RETRY_DELAY:-2}"
        done
        # 换镜像前清理半截文件，避免错误内容被续传拼接
        rm -f "$temp_output"

        log_warn "下载来源失败，尝试下一个: $source"
    done

    rm -f "$temp_output"

    log_error "所有镜像下载失败: $original_url"
    log_error "可设置 GITHUB_MIRRORS 使用自定义模板，或检查网络、DNS 与防火墙设置"
    return 1
}

# 创建便捷命令
create_convenience_commands() {
    # clashon - 启动服务
    cat > /usr/local/bin/clashon << 'EOF'
#!/bin/bash
echo "🚀 启动 Mihomo 服务..."
if systemctl start mihomo; then
    echo "✅ Mihomo 服务已启动"
    echo "🌐 管理界面: http://$(hostname -I | awk '{print $1}'):9090"
else
    echo "❌ 启动失败，请检查日志: journalctl -u mihomo"
fi
EOF

    # clashoff - 停止服务并清理代理
    cat > /usr/local/bin/clashoff << 'EOF'
#!/bin/bash
echo "🛑 停止 Mihomo 服务..."
if systemctl stop mihomo; then
    echo "✅ Mihomo 服务已停止"
    # 清理系统代理
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    unset all_proxy ALL_PROXY no_proxy NO_PROXY
    echo "🧹 系统代理已清理"
else
    echo "❌ 停止失败，请检查日志: journalctl -u mihomo"
fi
EOF

    # clashstatus - 查看状态
    cat > /usr/local/bin/clashstatus << 'EOF'
#!/bin/bash
echo "📊 Mihomo 服务状态"
systemctl status mihomo --no-pager
echo ""
echo "🔌 端口监听状态"
netstat -tlnp | grep -E ":(7890|7891|9090)" || echo "没有监听端口"
EOF

    # clashlog - 查看日志
    cat > /usr/local/bin/clashlog << 'EOF'
#!/bin/bash
echo "📋 Mihomo 实时日志 (Ctrl+C 退出)"
journalctl -u mihomo -f
EOF

    # clashrestart - 重启服务
    cat > /usr/local/bin/clashrestart << 'EOF'
#!/bin/bash
echo "🔄 重启 Mihomo 服务..."
systemctl restart mihomo && echo "✅ Mihomo 服务已重启"
EOF

    # clashuninstall - 完整卸载
    cat > /usr/local/bin/clashuninstall << 'EOF'
#!/bin/bash
echo "🗑️  启动 Mihomo 卸载程序..."
if [ -f "/etc/mihomo/uninstall.sh" ]; then
    bash /etc/mihomo/uninstall.sh
elif [ -f "$(dirname "$0")/uninstall.sh" ]; then
    bash "$(dirname "$0")/uninstall.sh"
elif [ -f "/usr/local/share/mihomo/uninstall.sh" ]; then
    bash /usr/local/share/mihomo/uninstall.sh
else
    echo "❌ 未找到卸载脚本"
    echo "请手动下载并运行: https://github.com/ForLoveIcu/mihomo-for-linux-install/raw/master/uninstall.sh"
    echo "或使用命令: curl -fsSL https://github.com/ForLoveIcu/mihomo-for-linux-install/raw/master/uninstall.sh | sudo bash"
fi
EOF

    # clashfrontend - 前端管理
    cat > /usr/local/bin/clashfrontend << 'EOF'
#!/bin/bash
echo "🎨 启动前端管理工具..."
if [ -f "/etc/mihomo/frontend_manager.sh" ]; then
    bash /etc/mihomo/frontend_manager.sh "$@"
else
    echo "❌ 前端管理脚本不存在"
    echo "请重新安装或手动下载: https://github.com/ForLoveIcu/mihomo-for-linux-install/raw/master/frontend_manager.sh"
fi
EOF

    chmod +x /usr/local/bin/clash{on,off,status,log,restart,uninstall,frontend}
}

# 前端选择函数
choose_frontend() {
    echo ""
    echo -e "${CYAN}🎨 选择前端界面${NC}"
    echo -e "${CYAN}================================${NC}"
    echo ""
    echo "请选择要安装的前端界面："
    echo ""
    echo "  1) MetaCubeXD (推荐)"
    echo "     • 官方维护，功能完整"
    echo "     • 稳定可靠，兼容性好"
    echo "     • 适合生产环境使用"
    echo ""
    echo "  2) Zashboard"
    echo "     • 现代化设计，界面美观"
    echo "     • 移动端友好，响应式布局"
    echo "     • 基于 Vue 3，性能优秀"
    echo ""

    while true; do
        read -p "请输入选择 [1-2] (默认: 1): " frontend_choice
        frontend_choice=${frontend_choice:-1}

        case "$frontend_choice" in
            1)
                SELECTED_FRONTEND="metacubexd"
                log_info "已选择: MetaCubeXD"
                break
                ;;
            2)
                SELECTED_FRONTEND="zashboard"
                log_info "已选择: Zashboard"
                break
                ;;
            *)
                echo "❌ 无效选择，请输入 1 或 2"
                ;;
        esac
    done
}


# 安装 MetaCubeXD 前端
install_metacubexd() {
    log_info "安装 MetaCubeXD 前端..."
    local download_url="https://github.com/MetaCubeX/metacubexd/releases/download/v1.189.0/compressed-dist.tgz"
    download_file "$download_url" "/tmp/ui.tgz"
    rm -rf /etc/mihomo/ui
    mkdir -p /etc/mihomo/ui
    tar -xzf /tmp/ui.tgz -C /etc/mihomo/ui
    echo "metacubexd" > /etc/mihomo/ui/.frontend_info
    echo "MetaCubeXD v1.189.0" > /etc/mihomo/ui/.frontend_version
    log_success "MetaCubeXD 前端安装完成"
}

# 安装 Zashboard 前端
install_zashboard() {
    log_info "安装 Zashboard 前端..."
    local download_url="https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip"
    download_file "$download_url" "/tmp/ui.zip"
    rm -rf /etc/mihomo/ui
    mkdir -p /etc/mihomo/ui
    unzip -q /tmp/ui.zip -d /etc/mihomo/ui
    echo "zashboard" > /etc/mihomo/ui/.frontend_info
    echo "Zashboard latest" > /etc/mihomo/ui/.frontend_version
    log_success "Zashboard 前端安装完成"
}

# 安装前端界面
install_frontend() {
    # 如果没有选择前端，进行选择
    if [ -z "$SELECTED_FRONTEND" ]; then
        choose_frontend
    fi

    case "$SELECTED_FRONTEND" in
        "metacubexd")
            install_metacubexd
            ;;
        "zashboard")
            install_zashboard
            ;;
        *)
            log_warn "未知前端选择，使用默认的 MetaCubeXD"
            install_metacubexd
            ;;
    esac
}

# 主安装函数
main() {
    log_info "开始安装 Mihomo..."

    # 加载配置
    load_config

    # 检查权限
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi

    # 检查并处理已存在的安装
    if [ -f "/opt/mihomo/mihomo" ] || [ -d "/etc/mihomo" ]; then
        log_warn "检测到 Mihomo 已安装。"
        read -p "是否要覆盖安装？[y/N]: " choice
        choice=${choice:-N}

        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log_info "操作已取消。"
            exit 0
        fi

        if systemctl is-active --quiet mihomo; then
            log_info "正在停止现有的 Mihomo 服务..."
            systemctl stop mihomo
        fi
    fi
    
    # 检测架构并获取对应的文件名
    local arch_name=$(uname -m)
    local arch_file=$(detect_arch)
    log_info "检测到架构: $arch_name"
    log_info "目标版本: $MIHOMO_VERSION"
    log_info "下载文件: $arch_file"

    # 验证架构文件名不为空
    if [ -z "$arch_file" ]; then
        log_error "无法确定架构对应的文件名"
        exit 1
    fi

    # 安装依赖
    install_dependencies

    # 创建目录
    mkdir -p /etc/mihomo
    mkdir -p /opt/mihomo

    # 下载 Mihomo 核心
    local mihomo_url="${MIHOMO_BASE_URL}/${arch_file}"
    log_info "下载地址: $mihomo_url"
    download_file "$mihomo_url" "/tmp/mihomo.gz"
    
    # 解压并安装
    gunzip -c /tmp/mihomo.gz > /opt/mihomo/mihomo
    chmod +x /opt/mihomo/mihomo
    
    # 安装前端界面
    if [ ! -f "/etc/mihomo/ui/.frontend_info" ]; then
        install_frontend
    else
        log_info "检测到已安装前端UI，跳过安装。如需更换，请使用 'clashfrontend' 命令。"
    fi
    
    # 创建配置文件
    if [ ! -f "/etc/mihomo/config.yaml" ]; then
        cat > /etc/mihomo/config.yaml << 'EOF'
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
external-controller: 0.0.0.0:9090
external-ui: ui

dns:
  enable: true
  listen: 0.0.0.0:53
  nameserver:
    - 8.8.8.8
    - 1.1.1.1

proxies: []

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - DIRECT

rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - MATCH,PROXY
EOF
    fi
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/mihomo.service << 'EOF'
[Unit]
Description=Mihomo Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=/opt/mihomo/mihomo -d /etc/mihomo
WorkingDirectory=/etc/mihomo

[Install]
WantedBy=multi-user.target
EOF
    
    # 重载并启动服务
    systemctl daemon-reload
    systemctl enable mihomo
    systemctl start mihomo
    
    # 创建完整的便捷命令系统
    create_convenience_commands

    log_success "便捷命令已创建: clashon, clashoff, clashstatus, clashlog, clashrestart, clashuninstall, clashfrontend"

    # 下载并安装管理脚本
    log_info "安装管理脚本..."
    if download_file "https://github.com/ForLoveIcu/mihomo-for-linux-install/raw/master/uninstall.sh" "/etc/mihomo/uninstall.sh"; then
        chmod +x /etc/mihomo/uninstall.sh
    fi
    if download_file "https://github.com/ForLoveIcu/mihomo-for-linux-install/raw/master/frontend_manager.sh" "/etc/mihomo/frontend_manager.sh"; then
        chmod +x /etc/mihomo/frontend_manager.sh
    fi
    log_success "管理脚本已安装到 /etc/mihomo/"

    # 清理临时文件
    rm -f /tmp/mihomo.gz /tmp/ui.tgz /tmp/ui.zip
    
    log_success "Mihomo 安装完成！"
    log_info "管理界面: http://$(hostname -I | awk '{print $1}'):9090"
    log_info "使用 'clashon' 启动，'clashoff' 停止"
}

# 执行主函数
main "$@"
