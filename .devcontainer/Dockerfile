FROM node:20-bookworm

ARG TZ=UTC
ENV TZ="$TZ"
ARG CLAUDE_CODE_VERSION=latest

# Install development tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    less \
    git \
    procps \
    sudo \
    fzf \
    zsh \
    man-db \
    unzip \
    gnupg2 \
    jq \
    nano \
    vim \
    curl \
    wget \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    socat \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Setup node user with sudo access
RUN echo "node ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/node

# Setup npm global directory
RUN mkdir -p /usr/local/share/npm-global \
    && chown -R node:node /usr/local/share/npm-global

# Persist command history
RUN mkdir -p /commandhistory \
    && touch /commandhistory/.bash_history \
    && touch /commandhistory/.zsh_history \
    && chown -R node:node /commandhistory

# Create workspace and claude config directories
RUN mkdir -p /workspace /home/node/.claude /home/node/.ssh \
    && chown -R node:node /workspace /home/node/.claude /home/node/.ssh

WORKDIR /workspace

USER node

# Environment setup
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV SHELL=/bin/zsh
ENV EDITOR=nano
ENV VISUAL=nano
ENV HISTFILE=/commandhistory/.zsh_history
ENV DEVCONTAINER=true

# Configure git to use HTTPS instead of SSH (since SSH doesn't go through proxy easily)
RUN git config --global url."https://github.com/".insteadOf git@github.com: \
    && git config --global url."https://github.com/".insteadOf ssh://git@github.com/

# Configure SSH to use proxy for github.com (alternative to HTTPS)
# This uses socat to tunnel SSH through the HTTP proxy's CONNECT method
RUN echo "Host github.com" >> ~/.ssh/config \
    && echo "    HostName github.com" >> ~/.ssh/config \
    && echo "    User git" >> ~/.ssh/config \
    && echo "    ProxyCommand socat - PROXY:proxy:%h:%p,proxyport=3128" >> ~/.ssh/config \
    && chmod 600 ~/.ssh/config

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}


# Default command
CMD ["bash"]
