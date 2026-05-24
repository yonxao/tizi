#!/bin/bash

# =========================
# Mihomo 配置构建脚本
# =========================
# 目标：
# 1. VPS 上分文件维护源配置；
# 2. secrets/env.secret 留在 VPS 本地，不进入 Git；
# 3. 支持 Mac / Android 两个客户端；
# 4. 支持 fake-ip / redir-host 两种 DNS 模式；
# 5. 支持 blockudp443 / allowudp443 两种 UDP/443 策略；
# 6. 最终生成 2 × 2 × 2 = 8 个订阅文件；
# 7. 发布文件自动去除注释；
# 8. 输出目录可在 secrets/env.secret 中配置；
# 9. 也支持命令行临时覆盖输出目录，例如：
#    OUT_DIR="./test-output" ./build.sh

set -euo pipefail

# =========================
# 路径定义
# =========================

# 自动获取 build.sh 所在目录。
# 这样整个项目移动位置后，不需要修改 SRC_DIR。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# 源配置根目录。
# 默认就是 build.sh 所在目录。
SRC_DIR="$SCRIPT_DIR"

# 通用配置目录。
COMMON_DIR="$SRC_DIR/common"

# DNS 模式目录。
DNS_MODE_DIR="$SRC_DIR/dns-modes"

# 规则片段目录。
RULES_DIR="$SRC_DIR/rules"

# 客户端差异配置目录。
CLIENT_DIR="$SRC_DIR/clients"

# secrets 文件。
SECRETS_FILE="$SRC_DIR/secrets/env.secret"

# 输出目录。
# 注意：这里先不写死最终值。
# 最终优先级：
# 1. 命令行环境变量 OUT_DIR
# 2. secrets/env.secret 里的 MIHOMO_OUT_DIR
# 3. 默认 /var/www/html/kxmfwzjy
OUT_DIR="${OUT_DIR:-}"

# 输出文件权限。
# 最终优先级：
# 1. 命令行环境变量 OUT_MODE
# 2. secrets/env.secret 里的 MIHOMO_OUT_MODE
# 3. 默认 644
OUT_MODE="${OUT_MODE:-}"

# =========================
# 日志函数
# =========================

log_info() {
    echo "[INFO] $*"
}

log_ok() {
    echo "[OK] $*"
}

log_warn() {
    echo "[WARN] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

# =========================
# 基础检查函数
# =========================

check_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        log_error "文件不存在：$file"
        exit 1
    fi
}

check_dir() {
    local dir="$1"

    if [ ! -d "$dir" ]; then
        log_error "目录不存在：$dir"
        exit 1
    fi
}

check_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        log_error "未找到命令：$command_name"
        exit 1
    fi
}

check_yq() {
    check_command yq

    # 本脚本依赖 Mike Farah yq v4。
    # Debian 仓库里的 yq 有时是 Python yq，不兼容 eval-all。
    local version
    version="$(yq --version 2>/dev/null || true)"

    if ! echo "$version" | grep -qiE 'mike farah|version v4|v4\.'; then
        log_warn "当前 yq 版本信息：$version"
        log_warn "本脚本需要 Mike Farah yq v4；如果 eval-all 报错，请重新安装 yq v4"
    fi
}

check_required_files() {
    # 检查目录。
    check_dir "$COMMON_DIR"
    check_dir "$DNS_MODE_DIR"
    check_dir "$RULES_DIR"
    check_dir "$CLIENT_DIR"
    check_dir "$(dirname "$SECRETS_FILE")"

    # 检查 secrets。
    check_file "$SECRETS_FILE"

    # 检查通用配置。
    check_file "$COMMON_DIR/01-base.yaml"
    check_file "$COMMON_DIR/02-dns-base.yaml"
    check_file "$COMMON_DIR/03-proxies.template.yaml"
    check_file "$COMMON_DIR/04-groups.yaml"

    # 检查 DNS 模式。
    check_file "$DNS_MODE_DIR/fake-ip.yaml"
    check_file "$DNS_MODE_DIR/redir-host.yaml"

    # 检查规则片段。
    check_file "$RULES_DIR/00-local.yaml"
    check_file "$RULES_DIR/01-vps-direct.yaml"
    check_file "$RULES_DIR/10-udp443-block.yaml"
    check_file "$RULES_DIR/10-udp443-allow.yaml"
    check_file "$RULES_DIR/20-reject.yaml"
    check_file "$RULES_DIR/30-proxy-ai.yaml"
    check_file "$RULES_DIR/31-proxy-developer.yaml"
    check_file "$RULES_DIR/32-proxy-google.yaml"
    check_file "$RULES_DIR/33-proxy-social.yaml"
    check_file "$RULES_DIR/34-proxy-microsoft.yaml"
    check_file "$RULES_DIR/40-apple.yaml"
    check_file "$RULES_DIR/50-direct-domestic.yaml"
    check_file "$RULES_DIR/90-final.yaml"

    # 检查客户端配置。
    check_file "$CLIENT_DIR/mac.yaml"
    check_file "$CLIENT_DIR/android.yaml"
}

# =========================
# 加载 secrets
# =========================

load_secrets() {
    # 读取 secrets/env.secret。
    # 这个文件不进 Git，只保存在 VPS。
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"

    # =========================
    # 检查必需变量
    # =========================

    : "${REALITY_NAME:?REALITY_NAME 未设置}"
    : "${REALITY_SERVER:?REALITY_SERVER 未设置}"
    : "${REALITY_PORT:?REALITY_PORT 未设置}"
    : "${REALITY_UUID:?REALITY_UUID 未设置}"
    : "${REALITY_SERVERNAME:?REALITY_SERVERNAME 未设置}"
    : "${REALITY_PUBLIC_KEY:?REALITY_PUBLIC_KEY 未设置}"
    : "${REALITY_SHORT_ID:?REALITY_SHORT_ID 未设置}"
    : "${MIHOMO_SECRET:?MIHOMO_SECRET 未设置}"
    : "${VPS_MANAGE_IP:?VPS_MANAGE_IP 未设置}"

    # =========================
    # 输出目录与权限
    # =========================
    # 优先级：
    # 1. 命令行 OUT_DIR="./test-output" ./build.sh
    # 2. secrets/env.secret 里的 MIHOMO_OUT_DIR
    # 3. 默认 /var/www/html/kxmfwzjy

    OUT_DIR="${OUT_DIR:-${MIHOMO_OUT_DIR:-/var/www/html/kxmfwzjy}}"

    # 输出权限优先级：
    # 1. 命令行 OUT_MODE="644" ./build.sh
    # 2. secrets/env.secret 里的 MIHOMO_OUT_MODE
    # 3. 默认 644

    OUT_MODE="${OUT_MODE:-${MIHOMO_OUT_MODE:-644}}"

    # 创建输出目录。
    mkdir -p "$OUT_DIR"

    # =========================
    # 导出变量给 envsubst 使用
    # =========================

    export REALITY_NAME
    export REALITY_SERVER
    export REALITY_PORT
    export REALITY_UUID
    export REALITY_SERVERNAME
    export REALITY_PUBLIC_KEY
    export REALITY_SHORT_ID
    export MIHOMO_SECRET
    export VPS_MANAGE_IP

    # 输出目录通常不需要注入 YAML，但导出无害，方便以后扩展模板。
    export MIHOMO_OUT_DIR="${MIHOMO_OUT_DIR:-$OUT_DIR}"
    export MIHOMO_OUT_MODE="${MIHOMO_OUT_MODE:-$OUT_MODE}"
}

# =========================
# DNS 模式选择
# =========================

get_dns_mode_file() {
    local dns_mode="$1"

    case "$dns_mode" in
        fake-ip)
            echo "$DNS_MODE_DIR/fake-ip.yaml"
            ;;
        redir-host)
            echo "$DNS_MODE_DIR/redir-host.yaml"
            ;;
        *)
            log_error "未知 DNS 模式：$dns_mode，只允许 fake-ip 或 redir-host"
            exit 1
            ;;
    esac
}

# =========================
# UDP/443 策略选择
# =========================

get_udp_policy_file() {
    local udp_policy="$1"

    case "$udp_policy" in
        blockudp443)
            echo "$RULES_DIR/10-udp443-block.yaml"
            ;;
        allowudp443)
            echo "$RULES_DIR/10-udp443-allow.yaml"
            ;;
        *)
            log_error "未知 UDP 策略：$udp_policy，只允许 blockudp443 或 allowudp443"
            exit 1
            ;;
    esac
}

# =========================
# 渲染模板
# =========================

render_template() {
    local template_file="$1"
    local output_file="$2"

    # envsubst 会替换文件中的 ${REALITY_SERVERNAME} 等变量。
    # 当前用于：
    # - common/01-base.yaml
    # - common/03-proxies.template.yaml
    # - rules/10-udp443-*.yaml
    # 也支持以后其他规则片段使用变量。
    envsubst < "$template_file" > "$output_file"

    # 渲染后立即检查 YAML 语法。
    yq eval '.' "$output_file" >/dev/null
}

# =========================
# 合并 rules 片段
# =========================

build_rules_file() {
    local output_file="$1"
    local udp_policy="$2"

    local network_control_file
    network_control_file="$(get_udp_policy_file "$udp_policy")"

    log_info "正在合并 rules，UDP策略=$udp_policy"

    # 临时目录用于保存渲染后的 rules 片段。
    local rules_tmp_dir
    rules_tmp_dir="$(mktemp -d)"

    # 手动清理，避免嵌套 trap 互相覆盖。
    local rendered_00="$rules_tmp_dir/00-local.yaml"
    local rendered_01="$rules_tmp_dir/01-vps-direct.yaml"
    local rendered_10="$rules_tmp_dir/10-udp443.yaml"
    local rendered_20="$rules_tmp_dir/20-reject.yaml"
    local rendered_30="$rules_tmp_dir/30-proxy-ai.yaml"
    local rendered_31="$rules_tmp_dir/31-proxy-developer.yaml"
    local rendered_32="$rules_tmp_dir/32-proxy-google.yaml"
    local rendered_33="$rules_tmp_dir/33-proxy-social.yaml"
    local rendered_34="$rules_tmp_dir/34-proxy-microsoft.yaml"
    local rendered_40="$rules_tmp_dir/40-apple.yaml"
    local rendered_50="$rules_tmp_dir/50-direct-domestic.yaml"
    local rendered_90="$rules_tmp_dir/90-final.yaml"

    # 所有 rules 片段都先经过 envsubst。
    # 01-vps-direct.yaml 会使用 ${VPS_MANAGE_IP}
    # 10-udp443-*.yaml 会使用 ${REALITY_SERVERNAME}
    render_template "$RULES_DIR/00-local.yaml" "$rendered_00"
    render_template "$RULES_DIR/01-vps-direct.yaml" "$rendered_01"
    render_template "$network_control_file" "$rendered_10"
    render_template "$RULES_DIR/20-reject.yaml" "$rendered_20"
    render_template "$RULES_DIR/30-proxy-ai.yaml" "$rendered_30"
    render_template "$RULES_DIR/31-proxy-developer.yaml" "$rendered_31"
    render_template "$RULES_DIR/32-proxy-google.yaml" "$rendered_32"
    render_template "$RULES_DIR/33-proxy-social.yaml" "$rendered_33"
    render_template "$RULES_DIR/34-proxy-microsoft.yaml" "$rendered_34"
    render_template "$RULES_DIR/40-apple.yaml" "$rendered_40"
    render_template "$RULES_DIR/50-direct-domestic.yaml" "$rendered_50"
    render_template "$RULES_DIR/90-final.yaml" "$rendered_90"

    # 合并所有 rules 数组。
    # 注意：01-vps-direct 必须放在 00-local 后、10-udp443 前。
    yq eval-all '
      . as $item ireduce ([]; . + ($item.rules // []))
      | {"rules": .}
    ' \
      "$rendered_00" \
      "$rendered_01" \
      "$rendered_10" \
      "$rendered_20" \
      "$rendered_30" \
      "$rendered_31" \
      "$rendered_32" \
      "$rendered_33" \
      "$rendered_34" \
      "$rendered_40" \
      "$rendered_50" \
      "$rendered_90" \
      > "$output_file"

    # 清理 rules 临时目录。
    rm -rf "$rules_tmp_dir"

    # 检查合并后的 rules 文件是否是合法 YAML。
    yq eval '.' "$output_file" >/dev/null

    local rules_count
    rules_count="$(yq eval '.rules | length' "$output_file")"

    if [ "$rules_count" -le 0 ]; then
        log_error "合并后的 rules 为空"
        exit 1
    fi

    log_ok "rules 合并完成，数量=$rules_count"
}

# =========================
# 去注释并格式化
# =========================

format_without_comments() {
    local input_file="$1"
    local output_file="$2"

    # 先转 JSON 再转 YAML。
    # JSON 不支持注释，所以注释会被去除。
    # 最终发布给客户端的是无注释、格式化后的干净 YAML。
    yq eval -o=json '.' "$input_file" | yq eval -P '.' - > "$output_file"
}

# =========================
# 最终配置校验
# =========================

validate_final_config() {
    local file="$1"
    local profile_name="$2"

    # 检查 YAML 可解析。
    yq eval '.' "$file" >/dev/null

    # 检查 rules 不为空。
    local rules_count
    rules_count="$(yq eval '.rules | length' "$file")"

    if [ "$rules_count" -le 0 ]; then
        log_error "最终配置 rules 为空：$profile_name"
        exit 1
    fi

    # 检查 proxy-groups 不为空。
    local groups_count
    groups_count="$(yq eval '.proxy-groups | length' "$file")"

    if [ "$groups_count" -le 0 ]; then
        log_error "最终配置 proxy-groups 为空：$profile_name"
        exit 1
    fi

    # 检查 proxies 不为空。
    local proxies_count
    proxies_count="$(yq eval '.proxies | length' "$file")"

    if [ "$proxies_count" -le 0 ]; then
        log_error "最终配置 proxies 为空：$profile_name"
        exit 1
    fi

    # 检查最终文件里是否仍残留未替换变量。
    if grep -q '\${[A-Za-z_][A-Za-z0-9_]*}' "$file"; then
        log_error "最终配置仍存在未替换变量：$profile_name"
        grep '\${[A-Za-z_][A-Za-z0-9_]*}' "$file" >&2 || true
        exit 1
    fi

    log_ok "配置检查通过：${profile_name}，rules=${rules_count}，groups=${groups_count}，proxies=${proxies_count}"
}

# =========================
# 构建单个配置
# =========================

build_one() {
    local output_name="$1"    # 输出文件名，例如 mihomo-mac-fakeip-blockudp443
    local client_file="$2"    # 客户端配置，例如 clients/mac.yaml
    local udp_policy="$3"     # blockudp443 或 allowudp443
    local dns_mode="$4"       # fake-ip 或 redir-host

    local out_file="$OUT_DIR/$output_name"

    local dns_mode_file
    dns_mode_file="$(get_dns_mode_file "$dns_mode")"

    log_info "开始构建：${output_name}，UDP=${udp_policy}，DNS=${dns_mode}"

    # 临时目录。
    # 构建过程中所有中间文件都放这里，成功后只输出最终文件。
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    local rendered_base="$tmp_dir/01-base.rendered.yaml"
    local rendered_proxies="$tmp_dir/03-proxies.rendered.yaml"
    local generated_rules_file="$tmp_dir/generated-rules.yaml"
    local merged_file="$tmp_dir/merged.yaml"
    local formatted_file="$tmp_dir/formatted.yaml"

    # 注意：
    # 这里不能写 trap 'rm -rf "$tmp_dir"' RETURN。
    # 因为单引号会导致 $tmp_dir 延迟展开，函数结束后变量失效，会触发 unbound variable。
    #
    # 这里用双引号，让 tmp_dir 在设置 trap 时就展开成具体路径。
    trap "rm -rf '$tmp_dir'" RETURN

    # 渲染带变量的模板。
    render_template "$COMMON_DIR/01-base.yaml" "$rendered_base"
    render_template "$COMMON_DIR/03-proxies.template.yaml" "$rendered_proxies"

    # 根据 UDP 策略合并 rules。
    build_rules_file "$generated_rules_file" "$udp_policy"

    # 结构化合并 YAML。
    #
    # 合并顺序很重要：
    # 1. base
    # 2. dns base
    # 3. dns mode，覆盖 enhanced-mode 等字段
    # 4. proxies
    # 5. proxy-groups
    # 6. generated rules
    # 7. client override
    #
    # 注意：
    # clients/*.yaml 不应该写 rules，否则会覆盖 generated rules。
    yq eval-all '
      . as $item ireduce ({}; . * $item)
    ' \
      "$rendered_base" \
      "$COMMON_DIR/02-dns-base.yaml" \
      "$dns_mode_file" \
      "$rendered_proxies" \
      "$COMMON_DIR/04-groups.yaml" \
      "$generated_rules_file" \
      "$client_file" \
      > "$merged_file"

    # 校验最终合并结果。
    validate_final_config "$merged_file" "$output_name"

    # 去注释并格式化。
    format_without_comments "$merged_file" "$formatted_file"

    # 防止空文件覆盖正式订阅。
    if [ ! -s "$formatted_file" ]; then
        log_error "生成结果为空：$output_name"
        exit 1
    fi

    # 原子覆盖输出文件。
    mv "$formatted_file" "$out_file"

    # 设置 Nginx 可读权限。
    chmod "$OUT_MODE" "$out_file"

    log_ok "已生成：$out_file"

    # 手动清理当前临时目录。
    rm -rf "$tmp_dir"

    # 清除 RETURN trap，避免它在 main 返回时再次执行。
    trap - RETURN
}

# =========================
# 主函数：生成 8 个订阅文件
# =========================

main() {
    check_command envsubst
    check_yq
    check_required_files
    load_secrets

    log_info "项目目录：${SRC_DIR}"
    log_info "输出目录：${OUT_DIR}"
    log_info "输出权限：${OUT_MODE}"

    # Mac + fake-ip + 禁止 UDP/443
    build_one "mihomo-mac-fakeip-blockudp443" "$CLIENT_DIR/mac.yaml" "blockudp443" "fake-ip"

    # Mac + fake-ip + 放开 UDP/443
    build_one "mihomo-mac-fakeip-allowudp443" "$CLIENT_DIR/mac.yaml" "allowudp443" "fake-ip"

    # Mac + redir-host + 禁止 UDP/443
    build_one "mihomo-mac-redirhost-blockudp443" "$CLIENT_DIR/mac.yaml" "blockudp443" "redir-host"

    # Mac + redir-host + 放开 UDP/443
    build_one "mihomo-mac-redirhost-allowudp443" "$CLIENT_DIR/mac.yaml" "allowudp443" "redir-host"

    # Android + fake-ip + 禁止 UDP/443
    build_one "mihomo-android-fakeip-blockudp443" "$CLIENT_DIR/android.yaml" "blockudp443" "fake-ip"

    # Android + fake-ip + 放开 UDP/443
    build_one "mihomo-android-fakeip-allowudp443" "$CLIENT_DIR/android.yaml" "allowudp443" "fake-ip"

    # Android + redir-host + 禁止 UDP/443
    build_one "mihomo-android-redirhost-blockudp443" "$CLIENT_DIR/android.yaml" "blockudp443" "redir-host"

    # Android + redir-host + 放开 UDP/443
    build_one "mihomo-android-redirhost-allowudp443" "$CLIENT_DIR/android.yaml" "allowudp443" "redir-host"

    log_ok "全部配置生成完成"
}

main "$@"