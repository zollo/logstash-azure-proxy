# syntax=docker/dockerfile:1

# Logstash version is compatible with the microsoft-logstash-output-azure-loganalytics
# plugin (supports 7.x, 8.0-8.9 and 8.11). Override at build time with --build-arg.
ARG LOGSTASH_VERSION=8.11.4

FROM docker.elastic.co/logstash/logstash:${LOGSTASH_VERSION}

LABEL org.opencontainers.image.title="logstash-azure-proxy" \
      org.opencontainers.image.description="Logstash with HTTP input, persistent queues and the Azure Log Analytics output plugin pre-installed" \
      org.opencontainers.image.source="https://github.com/zollo/logstash-azure-proxy"

# ---------------------------------------------------------------------------
# Install the Azure Log Analytics output plugin
# ---------------------------------------------------------------------------
RUN logstash-plugin install microsoft-logstash-output-azure-loganalytics

# ---------------------------------------------------------------------------
# Heap sizing: remove the hard-coded -Xms/-Xmx from the stock jvm.options so
# that the RAM-percentage flags supplied through LS_JAVA_OPTS take effect.
# (If -Xmx is set, the JVM ignores -XX:MaxRAMPercentage.)  This lets Logstash
# claim a majority of whatever memory the container is granted.
# ---------------------------------------------------------------------------
RUN sed -i -E \
        -e 's/^-Xms.*/## -Xms managed via LS_JAVA_OPTS RAM percentage/' \
        -e 's/^-Xmx.*/## -Xmx managed via LS_JAVA_OPTS RAM percentage/' \
        /usr/share/logstash/config/jvm.options

# Default heap = 75% of the container memory limit (a clear majority).  The JVM
# reads the cgroup limit, so this scales automatically with the memory assigned
# to the container.  Overridable at runtime via the LS_JAVA_OPTS env var.
ENV LS_JAVA_OPTS="-XX:InitialRAMPercentage=75 -XX:MinRAMPercentage=75 -XX:MaxRAMPercentage=75"

# Defaults for the persistent-queue settings referenced in logstash.yml.  These
# are overridable at runtime via environment variables.
ENV LS_QUEUE_PATH=/var/lib/logstash/queue \
    LS_QUEUE_MAX_BYTES=60gb \
    HTTP_PORT=8080

# ---------------------------------------------------------------------------
# Pre-built configuration
# ---------------------------------------------------------------------------
COPY --chown=logstash:logstash config/logstash.yml    /usr/share/logstash/config/logstash.yml
COPY --chown=logstash:logstash config/pipelines.yml   /usr/share/logstash/config/pipelines.yml
COPY --chown=logstash:logstash pipeline/              /usr/share/logstash/pipeline/

# ---------------------------------------------------------------------------
# Create the default persistent-queue directory owned by the logstash user.
# When a named volume is mounted here for the first time Docker copies this
# ownership onto the volume.
# ---------------------------------------------------------------------------
USER root
RUN mkdir -p /var/lib/logstash/queue \
 && chown -R logstash:logstash /var/lib/logstash
USER logstash

# HTTP input listener and the Logstash monitoring API.
EXPOSE 8080 9600

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
  CMD curl -fsS http://localhost:9600/ || exit 1
