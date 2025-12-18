#!/bin/bash
# Entrypoint script for Claude Code proxy container
# - Detects and configures upstream corporate proxy
# - Generates squid.conf from template
# - Optionally runs iptables hardening
# - Starts Squid

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[proxy]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[proxy]${NC} $1" >&2; }
log_error() { echo -e "${RED}[proxy]${NC} $1" >&2; }

# ============================================
# PARSE UPSTREAM PROXY
# ============================================
# Supports:
#   - UPSTREAM_PROXY=http://host:port
#   - UPSTREAM_PROXY=http://user:pass@host:port
#   - UPSTREAM_PROXY_USER + UPSTREAM_PROXY_PASS (separate)

parse_proxy_url() {
    local url="$1"

    # Remove protocol prefix
    url="${url#http://}"
    url="${url#https://}"

    # Check for credentials in URL (user:pass@host:port)
    if [[ "$url" == *"@"* ]]; then
        local auth="${url%%@*}"
        local hostport="${url#*@}"
        PROXY_USER="${auth%%:*}"
        PROXY_PASS="${auth#*:}"
        PROXY_HOST="${hostport%%:*}"
        PROXY_PORT="${hostport#*:}"
    else
        PROXY_HOST="${url%%:*}"
        PROXY_PORT="${url#*:}"
    fi

    # Remove trailing slashes from port
    PROXY_PORT="${PROXY_PORT%%/*}"

    # Default port if not specified
    [[ -z "$PROXY_PORT" || "$PROXY_PORT" == "$PROXY_HOST" ]] && PROXY_PORT="8080"
}

generate_upstream_config() {
    local config=""

    # Check for upstream proxy
    local upstream="${UPSTREAM_PROXY:-${HTTP_PROXY:-${http_proxy:-}}}"

    if [[ -n "$upstream" ]]; then
        log_info "Detected upstream proxy: $upstream"

        # Parse the proxy URL
        PROXY_HOST=""
        PROXY_PORT=""
        PROXY_USER="${UPSTREAM_PROXY_USER:-}"
        PROXY_PASS="${UPSTREAM_PROXY_PASS:-}"

        parse_proxy_url "$upstream"

        if [[ -n "$PROXY_HOST" ]]; then
            log_info "Configuring proxy chaining to $PROXY_HOST:$PROXY_PORT"

            # Build cache_peer directive
            config="cache_peer $PROXY_HOST parent $PROXY_PORT 0 no-query default"

            # Add authentication if provided
            if [[ -n "$PROXY_USER" && -n "$PROXY_PASS" ]]; then
                log_info "Using authenticated proxy (user: $PROXY_USER)"
                config="$config login=$PROXY_USER:$PROXY_PASS"
            fi

            # Force all traffic through parent proxy
            config="$config
never_direct allow all"
        fi
    else
        log_info "No upstream proxy detected - direct internet access"
    fi

    echo "$config"
}

# ============================================
# GENERATE SQUID CONFIG
# ============================================

generate_squid_config() {
    local template="/etc/squid/squid.conf.template"
    local output="/etc/squid/squid.conf"

    if [[ ! -f "$template" ]]; then
        log_error "Template not found: $template"
        exit 1
    fi

    # Generate upstream proxy config
    local upstream_config
    upstream_config=$(generate_upstream_config)

    # Replace placeholder in template
    awk -v config="$upstream_config" '
        /# @@UPSTREAM_PROXY_CONFIG@@/ {
            if (config != "") {
                print config
            }
            next
        }
        { print }
    ' "$template" > "$output"
    cat /etc/squid/squid.conf
    log_info "Generated squid.conf"
}

# ============================================
# IPTABLES HARDENING (if available)
# ============================================

run_firewall_hardening() {
    local firewall_script="/usr/local/bin/init-firewall.sh"

    if [[ -x "$firewall_script" ]]; then
        # Check if we have NET_ADMIN capability
        if capsh --print 2>/dev/null | grep -q cap_net_admin; then
            log_info "Running iptables hardening..."
            "$firewall_script"
        else
            log_warn "NET_ADMIN capability not available - skipping iptables hardening"
        fi
    else
        log_warn "Firewall script not found - skipping iptables hardening"
    fi
}

# ============================================
# ANTHROPIC API PROXY (credential isolation)
# ============================================

start_anthropic_proxy() {
    local proxy_script="/usr/local/bin/anthropic-proxy.py"

    if [[ -x "$proxy_script" ]]; then
        log_info "Starting Anthropic API proxy on port 3129..."
        python3 "$proxy_script" &
        ANTHROPIC_PROXY_PID=$!
        log_info "Anthropic proxy started (PID: $ANTHROPIC_PROXY_PID)"
    else
        log_warn "Anthropic proxy script not found - skipping"
    fi
}

# ============================================
# VALIDATE AND START
# ============================================

validate_config() {
    log_info "Validating Squid configuration..."
    if ! squid -k parse 2>&1; then
        log_error "Squid configuration validation failed"
        exit 1
    fi
    log_info "Configuration valid"
}

check_allowlist() {
    local allowlist="/etc/squid/allowlist.txt"
    if [[ ! -f "$allowlist" ]]; then
        log_error "Allowlist not found: $allowlist"
        exit 1
    fi

    local count
    count=$(grep -v '^#' "$allowlist" | grep -v '^$' | wc -l)
    log_info "Allowlist contains $count domains"
}

# ============================================
# MAIN
# ============================================

main() {
    log_info "Starting Claude Code proxy container"

    # Create log directory
    mkdir -p /var/log/squid
    chown proxy:proxy /var/log/squid

    # Generate config from template
    generate_squid_config

    # Check allowlist
    check_allowlist

    # Validate configuration
    validate_config

    # Run firewall hardening if available
    run_firewall_hardening

    # Start Anthropic API proxy (for credential isolation)
    start_anthropic_proxy

    # Start Squid in foreground
    log_info "Starting Squid proxy on port 3128..."
    exec squid -N -d 1
}

main "$@"
