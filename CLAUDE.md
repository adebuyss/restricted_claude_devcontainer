# CLAUDE.md


This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a network-restricted devcontainer for Claude Code using a Squid proxy sidecar. The Claude container runs on an internal Docker network with no direct internet access - all HTTP/HTTPS traffic routes through the proxy which enforces an allowlist.

## Architecture

Two containers orchestrated by Docker Compose:
- **claude-code**: Node 20 container with Claude Code CLI, on internal-only network (no internet)
- **proxy**: Squid proxy on both internal and external networks, with optional iptables hardening via NET_ADMIN capability

Traffic flow: `claude-code → proxy (Squid allowlist) → [optional corporate proxy] → internet`

## Common Commands

```bash
# Start the devcontainer
docker compose up -d

# Enter the Claude container
docker compose exec claude-code zsh

# View proxy logs (see allowed/blocked requests)
docker compose logs -f proxy

# Rebuild proxy after modifying allowlist
docker compose build proxy && docker compose up -d proxy

# Stop everything
docker compose down
```

## Key Files

- `.proxy/allowlist.txt` - Domains allowed through the proxy (edit and rebuild to modify)
- `.proxy/squid.conf.template` - Squid config template, `@@UPSTREAM_PROXY_CONFIG@@` replaced at runtime
- `.proxy/entrypoint.sh` - Parses corporate proxy env vars, generates squid.conf, runs firewall hardening, starts Anthropic proxy
- `.proxy/init-firewall.sh` - iptables/ipset hardening (runs if NET_ADMIN available)
- `.proxy/anthropic-proxy.py` - Reverse proxy for Anthropic API that injects API key (credential isolation)
- `.devcontainer/Dockerfile` - Claude container with Node 20, Claude CLI, git configured for HTTPS

## Corporate Proxy Support

Set `HTTP_PROXY` or `http_proxy` on the host before running `docker compose up`. Supports:
- URL with credentials: `http://user:pass@proxy:port`
- Separate credentials via `UPSTREAM_PROXY_USER` and `UPSTREAM_PROXY_PASS`

## Credential Isolation

Set `ANTHROPIC_API_KEY` on the host - it will only be passed to the proxy container, not the Claude container. The proxy injects the key into Anthropic API requests. If not set, requests pass through without injection (OAuth still works).

## Testing Network Restrictions

```bash
# Inside claude-code container:
curl -I https://api.github.com      # Should work (allowlisted)
curl -I https://google.com          # Should fail (403 from Squid)
curl --noproxy '*' https://google.com  # Should fail (no route)
```
