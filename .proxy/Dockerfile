FROM ubuntu:22.04

# Install Squid, firewall tools, and utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
    squid \
    curl \
    ca-certificates \
    # Firewall hardening tools (used if NET_ADMIN is available)
    iptables \
    ipset \
    # DNS resolution for allowlist
    dnsutils \
    # Capability checking
    libcap2-bin \
    # JSON parsing for GitHub API
    jq \
    # Python for Anthropic API proxy
    python3 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create log directory
RUN mkdir -p /var/log/squid && \
    chown proxy:proxy /var/log/squid

# Copy configuration files
COPY squid.conf.template /etc/squid/squid.conf.template
COPY allowlist.txt /etc/squid/allowlist.txt
COPY entrypoint.sh /entrypoint.sh
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY anthropic-proxy.py /usr/local/bin/anthropic-proxy.py

RUN chmod +x /entrypoint.sh /usr/local/bin/init-firewall.sh /usr/local/bin/anthropic-proxy.py && \
    chown proxy:proxy /etc/squid/squid.conf.template /etc/squid/allowlist.txt

EXPOSE 3128 3129

HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -sf -x http://localhost:3128 -o /dev/null http://pypi.org || exit 1

ENTRYPOINT ["/entrypoint.sh"]
