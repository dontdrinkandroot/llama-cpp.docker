FROM ghcr.io/ggml-org/llama.cpp:server-cuda

RUN apt-get update && \
    apt-get install -y --no-install-recommends aria2 ca-certificates curl && \
    rm -rf /var/lib/apt/lists/*

# Vast.ai installs openssh-server in its overlay and sets StrictModes no via sed,
# but Ubuntu 24.04 ships "#StrictModes yes" (commented) so the sed is a no-op and
# StrictModes defaults to yes, causing "bad ownership or modes for authorized_keys".
# This drop-in is loaded via the Include directive in sshd_config and survives
# the openssh-server install in vast.ai's overlay.
RUN mkdir -p /etc/ssh/sshd_config.d && \
    echo 'StrictModes no' > /etc/ssh/sshd_config.d/99-strictmodes-no.conf && \
    mkdir -p /root/.ssh && chmod 700 /root/.ssh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=1800s --retries=3 \
    CMD curl --fail http://localhost:${PORT:-8080}/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
