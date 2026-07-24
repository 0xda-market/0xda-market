# mcp-control VPS workload

The development VPS deploy packages a pinned, tested `mcp-control` commit and runs its read-only agent as the third workload beside the core API and bot.

```text
0xda-market      -> http://127.0.0.1:10000/health --┐
                                                    ├-> mcp-control agent
0xda-market-bot  -> http://127.0.0.1:10001/health --┘
```

## Runtime boundary

- `mcp-control` runs as numeric non-root user `65532`;
- the container root filesystem is read-only;
- all Linux capabilities are dropped;
- only host networking is used so the agent can reach loopback-only health ports;
- the Go transport independently rejects non-loopback destinations and redirects;
- no `mcp-control` port is published publicly;
- server manifests expose read-only health checks only;
- runtime and log adapters remain `none-v1`.

The agent Unix socket exists only in an ephemeral container `tmpfs`. There is no Dashboard, fleet protocol, Supabase connection, or write capability in this deployment.

## Verification

The core deployment fails and rolls back unless all three workloads are healthy. Its final checks run:

```sh
docker compose exec -T mcp-control \
  /opt/mcp-control/mcp-control servers validate \
  --config /etc/mcp-control/agent.json

docker compose exec -T mcp-control \
  /opt/mcp-control/mcp-control servers inspect 0xda-market \
  --config /etc/mcp-control/agent.json

docker compose exec -T mcp-control \
  /opt/mcp-control/mcp-control servers inspect 0xda-market-bot \
  --config /etc/mcp-control/agent.json
```

The deployment workflow builds static `linux/amd64` and `linux/arm64` binaries from a pinned Git commit and selects the host architecture on the VPS.
