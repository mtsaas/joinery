# joinery-relay Helm chart

Runs Joinery's relay, which passes live sessions between people without being able to read them
([docs/relay.md](../../docs/relay.md)). One relay, its WebSocket port and its Prometheus metrics.

```bash
helm install relay oci://ghcr.io/mtsaas/charts/joinery-relay --version 0.2.0
```

Chart versions match relay versions; the image is `ghcr.io/mtsaas/joinery-relay` at the chart's `appVersion`, for amd64
and arm64.

## What you need to add

**TLS.** The relay speaks plain WebSockets, and Joinery connects with `wss://`. Put something that ends TLS in front: the
chart's ingress, or a load balancer. Then enter its address, such as `wss://relay.example.com`, in Joinery ▸ Settings ▸
Sharing. Links name their relay, so people joining don't set anything.

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    # An idle session pings every 10 seconds; keep the timeout well above that.
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
  hosts:
    - host: relay.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: relay-tls
      hosts: [relay.example.com]
```

## One replica, by design

The chart always runs exactly one relay. Rooms live in its memory, and a room's host and guests must reach the same
relay, so a second replica behind the same Service would split rooms. Updates replace the pod (`Recreate`): sessions
drop for a moment, reconnect on their own, and catch up; a host has 30 seconds to come back before its room ends.

To serve more, run more releases, each with its own address: a link names its relay, so each room stays on the one
its host chose.

## Sizing

The relay counts the cores it can see, not its CPU limit, so set `threads` to about half the CPUs you give it: the
kernel's network work needs the rest, and more loops deliver less. Measured on 16 Arm cores and 64 GB, with 8 loops
(`relay/README.md` has more):

| Load | Relay used |
| --- | --- |
| 20,000 rooms of 4 (80,000 people), a change a second per host and 5 pointer updates per guest | under 2 cores, 1.4 GB |
| 1,000 full rooms of 32 (32,000 people), same rates | 4 cores, 0.55 GB |

Memory grows with connections, not traffic. The default `resources` (half a core and 256 MiB requested, a 2 GiB memory
limit) suit a few thousand people.

## Values

| Value | Default | What |
| --- | --- | --- |
| `image.repository` | `ghcr.io/mtsaas/joinery-relay` | |
| `image.tag` | the chart's `appVersion` | |
| `image.pullPolicy` | `IfNotPresent` | |
| `threads` | empty: half the node's cores | Event loops; set to about half the CPUs it's given |
| `batchMs` | `5` | How long, in ms, a connection's queue waits for more before it's sent: the same work with about 40% less CPU |
| `maxRooms` | `256` | Rooms held at once; past it, hosts are told the relay is full. At worst each holds about 4 MiB, so raise it with `resources.limits.memory` |
| `maxConnections` | `768` | Connections held at once; past it, new ones are closed. At worst each holds about 1 MiB of input |
| `maxOutboxMiB` | `128` | What all the connections' outboxes hold at once, in MiB; past it, the connection queued to is dropped as too far behind, and catches up when it comes back. Sized with the two above for 2Gi |
| `extraArgs` | `[]` | More `joinery-relay` flags |
| `service.type` | `ClusterIP` | |
| `service.port` | `8787` | WebSockets |
| `service.annotations` | `{}` | |
| `metrics.port` | `9187` | Prometheus metrics, at `/metrics` |
| `metrics.annotations` | `true` | `prometheus.io/scrape` annotations on the pod |
| `metrics.serviceMonitor.enabled` | `false` | A Prometheus Operator `ServiceMonitor` |
| `metrics.serviceMonitor.interval` | `30s` | |
| `metrics.serviceMonitor.labels` | `{}` | Labels your Prometheus selects on |
| `ingress.enabled` | `false` | |
| `ingress.className` | `""` | |
| `ingress.annotations` | `{}` | |
| `ingress.hosts` | `relay.example.com`, `/` | |
| `ingress.tls` | `[]` | |
| `resources` | 500m CPU and 256Mi requested, 2Gi memory limit | |
| `podAnnotations`, `podLabels`, `nodeSelector`, `tolerations`, `affinity` | empty | |

The pod runs as an unprivileged user with a read-only root filesystem and no capabilities. Readiness is the WebSocket
port accepting connections; liveness is `/metrics` answering.

## Metrics

`joinery_relay_*`: rooms, peers and connections open, bytes held in logs, frames and bytes in and out, rooms made and
ended, joins, changes, snapshots, connections closed for falling behind
(`joinery_relay_lagging_total`), and every connection let go of or turned away, by why
(`joinery_relay_dropped_total{reason=…}`). The relay's own memory and CPU are left to the cluster's usual exporters.
