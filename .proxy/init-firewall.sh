#!/bin/bash
# iptables hardening for Claude Code proxy container
# Provides defense-in-depth: even if Squid is bypassed, traffic is still filtered
# Requires NET_ADMIN capability

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[firewall]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[firewall]${NC} $1"; }

ALLOWLIST_FILE="/etc/squid/allowlist.txt"
IPSET_NAME="proxy_allowed"

# ============================================
# RESOLVE DOMAINS TO IPs
# ============================================

resolve_domains() {
    local domains_file="$1"

    if [[ ! -f "$domains_file" ]]; then
        log_warn "Allowlist file not found: $domains_file"
        return
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Remove leading dot for subdomain wildcards
        local domain="${line#.}"
        domain="${domain// /}"

        # Resolve A records
        local ips
        ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
        for ip in $ips; do
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                ipset add "$IPSET_NAME" "$ip" 2>/dev/null || true
            fi
        done
    done < "$domains_file"
}

# ============================================
# FETCH GITHUB IP RANGES
# ============================================

fetch_github_ips() {
    log_info "Fetching GitHub IP ranges..."

    local github_meta
    if github_meta=$(curl -s --max-time 10 "https://api.github.com/meta" 2>/dev/null); then
        for key in web api git packages actions; do
            local cidrs
            cidrs=$(echo "$github_meta" | grep -oP '"'"$key"'"\s*:\s*\[[^\]]*\]' | grep -oP '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' || true)
            for cidr in $cidrs; do
                ipset add "$IPSET_NAME" "$cidr" 2>/dev/null || true
            done
        done
        log_info "Added GitHub IP ranges"
    else
        log_warn "Could not fetch GitHub IP ranges"
    fi
}

# ============================================
# SETUP IPSET
# ============================================

setup_ipset() {
    # Create or flush ipset
    if ipset list "$IPSET_NAME" &>/dev/null; then
        ipset flush "$IPSET_NAME"
    else
        ipset create "$IPSET_NAME" hash:net
    fi
    log_info "Created ipset: $IPSET_NAME"

    # Resolve domains from allowlist
    log_info "Resolving allowed domains..."
    resolve_domains "$ALLOWLIST_FILE"

    # Fetch GitHub IPs
    fetch_github_ips

    local count
    count=$(ipset list "$IPSET_NAME" 2>/dev/null | grep -c "^[0-9]" || echo "0")
    log_info "ipset contains $count entries"
}

# ============================================
# SETUP IPTABLES
# ============================================

setup_iptables() {
    log_info "Configuring iptables rules..."

    # Flush existing rules
    iptables -F OUTPUT 2>/dev/null || true

    # Allow loopback
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow established/related connections
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow DNS (required for domain resolution)
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

    # Allow outbound to allowed IPs (HTTP/HTTPS)
    iptables -A OUTPUT -p tcp --dport 80 -m set --match-set "$IPSET_NAME" dst -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 443 -m set --match-set "$IPSET_NAME" dst -j ACCEPT

    # Allow SSH for git (to allowed IPs)
    iptables -A OUTPUT -p tcp --dport 22 -m set --match-set "$IPSET_NAME" dst -j ACCEPT

    # Allow connections to upstream proxy if configured
    if [[ -n "${UPSTREAM_PROXY:-}" ]]; then
        # Parse proxy host/port from environment
        local proxy_url="${UPSTREAM_PROXY#http://}"
        proxy_url="${proxy_url#https://}"
        proxy_url="${proxy_url#*@}"  # Remove credentials
        local proxy_host="${proxy_url%%:*}"
        local proxy_port="${proxy_url#*:}"
        proxy_port="${proxy_port%%/*}"
        [[ -z "$proxy_port" || "$proxy_port" == "$proxy_host" ]] && proxy_port="8080"

        # Resolve upstream proxy IP and allow
        local proxy_ips
        proxy_ips=$(dig +short "$proxy_host" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
        for ip in $proxy_ips; do
            iptables -A OUTPUT -p tcp -d "$ip" --dport "$proxy_port" -j ACCEPT
            log_info "Allowed upstream proxy: $ip:$proxy_port"
        done
    fi

    # Log and drop everything else (uncomment LOG for debugging)
    # iptables -A OUTPUT -j LOG --log-prefix "PROXY-BLOCKED: " --log-level 4
    iptables -A OUTPUT -j DROP

    log_info "iptables rules configured"
}

# ============================================
# MAIN
# ============================================

main() {
    log_info "Initializing firewall hardening..."

    # Check for required tools
    for cmd in iptables ipset dig; do
        if ! command -v "$cmd" &>/dev/null; then
            log_warn "Missing command: $cmd - skipping firewall setup"
            exit 0
        fi
    done

    # Setup ipset with allowed IPs
    setup_ipset

    # Setup iptables rules
    setup_iptables

    log_info "Firewall hardening complete"
}

main "$@"
