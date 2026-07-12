#!/bin/bash

# GitHub 镜像测试脚本
# 用于验证镜像 URL 模板是否正确，并测试各服务的可用性与完整下载耗时。

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

TEST_URL="${TEST_URL:-https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-amd64-compatible-v1.gz}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-120}"

# 每个模板中的 {url} 会被替换为完整的原始 GitHub HTTPS URL。
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

append_unique_source() {
    local candidate=$1
    local existing

    [ -z "$candidate" ] && return 0
    [ "$candidate" = "direct" ] && candidate="{url}"
    for existing in "${SOURCES[@]}"; do
        [ "$existing" = "$candidate" ] && return 0
    done
    SOURCES+=("$candidate")
}

build_sources() {
    local mirror
    SOURCES=()
    while IFS= read -r mirror; do
        append_unique_source "$mirror"
    done < <(get_github_mirrors)
    append_unique_source "{url}"
}

print_urls() {
    local source
    build_sources
    for source in "${SOURCES[@]}"; do
        build_download_url "$source" "$TEST_URL"
    done
}

test_download_speed() {
    local source=$1
    local download_url
    local temp_file
    local start_time
    local end_time
    local duration
    local file_size

    download_url=$(build_download_url "$source" "$TEST_URL")
    temp_file=$(mktemp "${TMPDIR:-/tmp}/mihomo-mirror-test.XXXXXX") || return 1

    if [ "$source" = "{url}" ]; then
        log_info "测试官方 GitHub 地址"
    else
        log_info "测试镜像模板: $source"
    fi

    start_time=$(date +%s)
    if curl -fL --connect-timeout "$CONNECT_TIMEOUT" --max-time "$DOWNLOAD_TIMEOUT" \
        --silent --show-error -o "$temp_file" "$download_url"; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        file_size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null || echo 0)
        if gzip -t "$temp_file" >/dev/null 2>&1; then
            log_success "下载和 gzip 校验成功：${duration} 秒，${file_size} bytes"
            TEST_DURATION=$duration
            rm -f "$temp_file"
            return 0
        fi
        log_warn "响应不是有效的 Mihomo gzip 文件"
    else
        log_warn "连接或下载失败"
    fi

    rm -f "$temp_file"
    return 1
}

main() {
    local source
    local best_source=""
    local best_time=-1
    local available=0

    if [ "${1:-}" = "--print-urls" ]; then
        print_urls
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "未找到 curl，无法执行镜像测试"
        return 1
    fi

    build_sources
    log_info "开始测试 GitHub 镜像服务..."
    echo "========================================"

    for source in "${SOURCES[@]}"; do
        echo ""
        if test_download_speed "$source"; then
            available=$((available + 1))
            if [ "$best_time" -lt 0 ] || [ "$TEST_DURATION" -lt "$best_time" ]; then
                best_time=$TEST_DURATION
                best_source=$source
            fi
        fi
        echo "----------------------------------------"
    done

    if [ "$available" -eq 0 ]; then
        log_error "所有镜像与官方 GitHub 地址都不可用，请检查网络、DNS 或防火墙"
        return 1
    fi

    log_success "测试完成：${available}/${#SOURCES[@]} 个来源可用"
    if [ "$best_source" = "{url}" ]; then
        log_info "最快来源：官方 GitHub（${best_time} 秒）"
    else
        log_info "最快来源：${best_source}（${best_time} 秒）"
    fi
}

main "$@"
