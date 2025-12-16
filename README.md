# Claude Code Devcontainer - Proxy Approach

This devcontainer uses a **Squid proxy sidecar** to restrict network access. The Claude container runs on an internal Docker network with no direct internet access - all HTTP/HTTPS traffic must go through the proxy.

## Features

- **Cross-platform** - Works on Linux and macOS (Docker Desktop)
- **Corporate proxy support** - Auto-detects and chains to upstream proxy
- **Defense-in-depth** - Squid allowlist + optional iptables hardening in proxy
- **No capabilities on Claude container** - NET_ADMIN/NET_RAW only on proxy

## Requirements

- Docker (Docker Desktop on macOS/Windows, or Docker Engine on Linux)
- Docker Compose v2
- No special host permissions required

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Docker Compose                               │
│                                                                     │
│  ┌─────────────────┐         ┌─────────────────┐                   │
│  │  claude-code    │         │     proxy       │                   │
│  │                 │ ──────► │    (Squid)      │ ──► Corporate ──► Internet
│  │  Internal       │  HTTP   │                 │     Proxy
│  │  Network Only   │  HTTPS  │  NET_ADMIN      │     (optional)
│  │                 │         │  NET_RAW        │                   │
│  │  NO caps        │         │  + iptables     │                   │
│  └─────────────────┘         └─────────────────┘                   │
│         │                           │                               │
│    ─────┴───────────────────────────┴─────                         │
│              Internal Network (no internet)                         │
└─────────────────────────────────────────────────────────────────────┘
```

## Usage

### With VS Code Dev Containers

1. Open this folder in VS Code
2. When prompted, click "Reopen in Container"
3. Docker Compose will start both containers automatically

### Manual Setup

```bash
# Start containers
docker compose up -d

# Enter the Claude container
docker compose exec claude-code zsh

# View proxy logs
docker compose logs -f proxy

# Stop everything
docker compose down
```

### Authentication

When running `claude` for the first time, you'll need to authenticate via OAuth. Due to network restrictions, the browser may not be able to reach the callback URL automatically.

**Workaround:** When the login URL appears in the terminal, manually copy and open it in your browser. After authenticating in the browser, you can then paste in the provided token.

## Corporate Proxy Support

If your environment uses a corporate proxy, the proxy container will automatically detect and chain to it.

### Auto-detection

Set one of these environment variables on the host before running `docker compose up`:
- `HTTP_PROXY`
- `http_proxy`

The value is passed to the proxy container's `UPSTREAM_PROXY` variable.

### Configuration Methods

**Method 1: URL with embedded credentials**
```bash
export HTTP_PROXY="http://user:password@corporate-proxy.example.com:8080"
docker compose up -d
```

**Method 2: Separate credentials**
```bash
export HTTP_PROXY="http://corporate-proxy.example.com:8080"
export UPSTREAM_PROXY_USER="myuser"
export UPSTREAM_PROXY_PASS="mypassword"
docker compose up -d
```

**Method 3: Using .env file**
Create a `.env` file in this directory:
```
HTTP_PROXY=http://corporate-proxy.example.com:8080
UPSTREAM_PROXY_USER=myuser
UPSTREAM_PROXY_PASS=mypassword
```

### Verify Corporate Proxy is Configured

```bash
docker compose logs proxy | grep -i upstream
# Should show: "Detected upstream proxy: http://..."
# And: "Configuring proxy chaining to corporate-proxy:8080"
```

## Credential Isolation

To prevent exfiltration of your Anthropic API key, you can configure the proxy to inject it rather than having it in the Claude container.

### Setup

```bash
# Set your API key on the host (it will only be passed to the proxy container)
export ANTHROPIC_API_KEY="sk-ant-..."
docker compose up -d
```

Or use a `.env` file:
```
ANTHROPIC_API_KEY=sk-ant-...
```

### How It Works

```
┌─────────────────┐         ┌─────────────────┐
│  claude-code    │  ───►   │     proxy       │  ───►  api.anthropic.com
│                 │  (no    │  :3129          │  (with
│  NO API KEY     │  key)   │  injects key    │   key)
└─────────────────┘         └─────────────────┘
```

1. Claude Code sends API requests to `http://proxy:3129` (via `ANTHROPIC_BASE_URL`)
2. The proxy intercepts requests and adds the `x-api-key` header
3. Request is forwarded to `api.anthropic.com` with the key
4. The API key never exists in the Claude container's environment or filesystem

### Verify Credential Isolation

```bash
# Check proxy has the key configured
docker compose logs proxy | grep -i "anthropic-proxy"
# Should show: "API key injection enabled: sk-ant-..."

# Verify Claude container does NOT have the key
docker compose exec claude-code env | grep -i anthropic
# Should show ANTHROPIC_BASE_URL but NOT ANTHROPIC_API_KEY
```

### Fallback Mode

If `ANTHROPIC_API_KEY` is not set, the proxy passes requests through without modification. This allows:
- OAuth login to work normally
- Using keys configured inside the container (less secure)

## Security Layers

### Layer 1: Network Isolation
- Claude container is on an `internal: true` Docker network
- No default gateway - cannot reach internet directly
- Can only communicate with proxy container

### Layer 2: Squid Allowlist
- Squid proxy only allows domains in `.proxy/allowlist.txt`
- All other domains are blocked with HTTP 403

### Layer 3: iptables Hardening (Defense-in-Depth)
- Proxy container has NET_ADMIN/NET_RAW capabilities
- On startup, runs `init-firewall.sh`:
  - Resolves allowlist domains to IPs
  - Creates ipset with allowed IPs
  - Configures iptables to DROP non-allowed traffic
- Even if Squid is somehow bypassed, traffic is still filtered

### Layer 4: Credential Isolation (Optional) (untested)
- API key lives only in the proxy container, never in Claude container
- Anthropic API requests route through a dedicated proxy (port 3129)
- The proxy injects the `x-api-key` header before forwarding to Anthropic
- Even if malicious code runs in Claude container, it cannot access the API key


## Testing

Inside the Claude container:

```bash
# These should WORK
curl -I https://api.github.com
curl -I https://registry.npmjs.org
curl -I https://api.anthropic.com
npm install express
pip install requests

# These should FAIL (blocked by proxy)
curl -I https://example.com
curl -I https://google.com

# Direct connections should also FAIL (no route)
curl --noproxy '*' https://google.com
```

## Allowed Destinations

Edit `.proxy/allowlist.txt` to modify the allowlist.

Current allowlist:
- GitHub (*.github.com, *.githubusercontent.com, *.githubassets.com)
- NPM Registry (*.npmjs.org, *.npmjs.com)
- PyPI (*.pypi.org, *.pythonhosted.org)
- VS Code (*.visualstudio.com, vscode.blob.core.windows.net, *.code.visualstudio.com, *.vo.msecnd.net)
- Anthropic (*.anthropic.com, claude.ai, *.claude.com)
- Sentry (sentry.io only, no subdomains)
- Statsig (statsig.anthropic.com, *.statsig.com)

After editing, rebuild the proxy:
```bash
docker compose build proxy
docker compose up -d proxy
```

## Git Configuration

By default, git is configured to use HTTPS instead of SSH:

```bash
git config --global url."https://github.com/".insteadOf git@github.com:
```

This ensures git operations go through the proxy.

### Using SSH for Git

If you need SSH git operations, the container is configured to tunnel SSH through the proxy using `socat`. This requires the proxy to allow CONNECT to port 22 (already configured).

## Proxy Logs

View what traffic is being allowed/blocked:

```bash
# Follow logs
docker compose logs -f proxy

# Or exec into proxy container
docker compose exec proxy tail -f /var/log/squid/access.log
```

## Troubleshooting

### "Connection refused" errors

Ensure the proxy container is running and healthy:
```bash
docker compose ps
docker compose logs proxy
```

### npm/pip not using proxy

Check environment variables are set:
```bash
env | grep -i proxy
```

Should show `HTTP_PROXY`, `HTTPS_PROXY`, etc.

### Corporate proxy authentication failing

Check proxy logs for authentication errors:
```bash
docker compose logs proxy | grep -i auth
```

Ensure credentials don't contain special characters that need URL encoding.

### iptables hardening not running

Check if NET_ADMIN capability is granted:
```bash
docker compose exec proxy capsh --print | grep cap_net_admin
```

Check firewall script output:
```bash
docker compose logs proxy | grep -i firewall
```

## Customization

### Add a domain to allowlist

Edit `.proxy/allowlist.txt`:
```
# My custom domain
.mycustomdomain.com
```

Then rebuild:
```bash
docker compose build proxy && docker compose up -d proxy
```

### Disable iptables hardening

Remove the `cap_add` section from `docker-compose.yml`:
```yaml
proxy:
  # cap_add:
  #   - NET_ADMIN
  #   - NET_RAW
```

### Mount host Claude config

To use your existing Claude configuration, edit `docker-compose.yml`:
```yaml
claude-code:
  volumes:
    - ${HOME}/.claude:/home/node/.claude:cached
```

## Security Notes

- DNS queries can still reach the internet (via Docker's DNS)
- Data could theoretically be exfiltrated via DNS tunneling
- The proxy logs all requests - review periodically
- The VS Code blob storage domain (`vscode.blob.core.windows.net`) is an Azure CDN endpoint
- **With credential isolation enabled**: API key cannot be exfiltrated as it never enters the Claude container
- **Without credential isolation**: Credentials could be exfiltrated via allowed domains (e.g., creating a GitHub gist)
