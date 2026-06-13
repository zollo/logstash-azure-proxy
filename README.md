# logstash-azure-proxy

A production-ready Logstash container that receives events over HTTP and ships
them to **Azure Log Analytics**. It ships pre-configured with:

- The **`http` input** plugin (listening on `:8080`).
- **Persistent Queues** enabled (`queue.type: persisted`) for durable, on-disk
  buffering so events survive restarts and downstream outages.
- The **`microsoft-logstash-output-azure-loganalytics`** output plugin
  pre-installed.
- An end-to-end **CI/CD pipeline** that builds the image and publishes it to the
  **GitHub Container Registry (GHCR)**.

## Image

```
ghcr.io/zollo/logstash-azure-proxy:latest
```

Built and pushed automatically by
[`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml)
on every push to `main` and on version tags (`vX.Y.Z`).

## Persistent queue configuration

The queue settings default to the values below and are overridable via
environment variables (using Logstash's `${VAR:default}` substitution in
[`config/logstash.yml`](config/logstash.yml)):

| Setting           | Env var              | Default                    |
| ----------------- | -------------------- | -------------------------- |
| `path.queue`      | `LS_QUEUE_PATH`      | `/var/lib/logstash/queue`  |
| `queue.max_bytes` | `LS_QUEUE_MAX_BYTES` | `60gb`                     |

## Memory

The JVM is configured to claim a **majority (75%) of the container's memory
limit** via `-XX:MaxRAMPercentage=75` (set through `LS_JAVA_OPTS`). The stock
`-Xms`/`-Xmx` lines are stripped from `jvm.options` at build time so the
percentage flags take effect. Because the JVM reads the cgroup memory limit,
the heap scales automatically with whatever memory the container is granted —
set `LS_MEM_LIMIT` in Compose and the heap follows.

## Running with Docker Compose

The provided [`docker-compose.yml`](docker-compose.yml) is production-ready with
dynamic CPU/memory allocation and mounted volumes for the queue and config.

1. Copy the env template and fill in your Azure workspace credentials:

   ```bash
   cp .env.example .env
   # edit .env -> set AZURE_WORKSPACE_ID and AZURE_WORKSPACE_KEY
   ```

2. Start the stack:

   ```bash
   docker compose up -d
   ```

3. Send a test event:

   ```bash
   curl -XPOST http://localhost:8080 -H 'Content-Type: application/json' \
        -d '{"message":"hello from logstash-azure-proxy"}'
   ```

### Tunable values (`.env`)

| Variable             | Default | Purpose                                   |
| -------------------- | ------- | ----------------------------------------- |
| `LS_CPU_LIMIT`       | `2`     | CPU limit for the container               |
| `LS_MEM_LIMIT`       | `4g`    | Memory limit (also drives the JVM heap)   |
| `LS_CPU_RESERVATION` | `1`     | Reserved CPUs                             |
| `LS_MEM_RESERVATION` | `2g`    | Reserved memory                           |
| `LS_QUEUE_PATH`      | `/var/lib/logstash/queue` | Persistent queue location |
| `LS_QUEUE_MAX_BYTES` | `60gb`  | Max persistent queue size                 |
| `HTTP_PORT`          | `8080`  | HTTP input listen port                    |
| `API_PORT`           | `9600`  | Logstash monitoring API port              |
| `AZURE_WORKSPACE_ID` | —       | **Required** — Log Analytics workspace ID |
| `AZURE_WORKSPACE_KEY`| —       | **Required** — Log Analytics primary key  |
| `AZURE_LOG_TABLE`    | `logstash` | Destination custom log table (`_CL`)   |

### Volumes

- `logstash-queue` — a named Docker volume mounted at `LS_QUEUE_PATH` to persist
  the on-disk queue across container restarts/upgrades.
- `./config/logstash.yml`, `./config/pipelines.yml`, `./pipeline/` — bind-mounted
  read-only so configuration can be tuned without rebuilding the image.

## Building locally

```bash
docker build -t logstash-azure-proxy:dev --build-arg LOGSTASH_VERSION=8.11.4 .
```

## Notes

- The plugin recommends disabling ECS on Logstash 8, so
  `pipeline.ecs_compatibility: disabled` is set in `logstash.yml`.
- For stronger security, prefer the Logstash keystore for
  `AZURE_WORKSPACE_KEY` instead of passing it as a plain environment variable.
