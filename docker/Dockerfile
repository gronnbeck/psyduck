# A psyduck host in a container: `psyduck serve`, with git, gh and claude.
# Build from the repo root:
#   docker build -f docker/Dockerfile -t psyduck-host .
# or use docker/compose.yml. See docs/REMOTE.md.

FROM swift:6.2-noble AS build
WORKDIR /src
COPY Package.swift ./
COPY Sources ./Sources
COPY Tests ./Tests
# The Swift runtime is linked in, so the final image needs no Swift.
RUN swift build -c release --product psyduck --static-swift-stdlib \
    && cp "$(swift build -c release --show-bin-path)/psyduck" /psyduck

FROM ubuntu:24.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git gh openssh-client \
    && rm -rf /var/lib/apt/lists/*

# claude refuses to skip permissions as root, so everything runs as `duck`.
RUN userdel -r ubuntu 2>/dev/null; useradd --create-home --shell /bin/bash duck \
    && mkdir /data && chown duck:duck /data
COPY --from=build /psyduck /usr/local/bin/psyduck
COPY docker/entrypoint.sh /usr/local/bin/psyduck-entrypoint
RUN chmod 755 /usr/local/bin/psyduck-entrypoint

USER duck
WORKDIR /home/duck
# The claude CLI, as its own installer lays it out (~/.local/bin/claude).
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && /home/duck/.local/bin/claude --version

# Everything that must outlive the container is under /data: psyduck's
# state and event logs, the repos and worktrees, and claude's own sessions
# (which `--resume` needs).
ENV PATH=/home/duck/.local/bin:$PATH \
    PSYDUCK_DATA=/data/state \
    PSYDUCK_CONFIG=/data/config.json \
    CLAUDE_CONFIG_DIR=/data/claude \
    DISABLE_AUTOUPDATER=1
VOLUME /data

ENTRYPOINT ["psyduck-entrypoint"]
