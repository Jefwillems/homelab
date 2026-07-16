# Technitium DNS

Self-hosted DNS + ad-blocking, deployed as plain kustomize manifests (there is no
official Helm chart). Runs in its own `technitium` namespace so it can live
alongside AdGuard during migration.

## Layout

| File                        | Purpose                                                     |
| --------------------------- | ----------------------------------------------------------- |
| `resources/deployment.yaml` | Technitium server (`/etc/dns` on a `local-path` PVC)        |
| `resources/pvc.yaml`        | 2Gi config volume                                           |
| `resources/service-dns.yaml`| LoadBalancer `192.168.178.249` (UDP+TCP 53), ETP `Local`   |
| `resources/service-web.yaml`| ClusterIP `5380` admin console                              |
| `resources/httproute.yaml`  | `technitium.jef.app` -> web console via the gateway         |

The DNS LoadBalancer IP (`192.168.178.249`) is announced on the LAN by Cilium L2
from the existing `pool` (`192.168.178.224/27`). AdGuard stays on `.250`.

## Required secret (create out-of-band, not in git)

The admin password is read from a Secret and set on first boot:

```sh
kubectl -n technitium create secret generic technitium-admin \
  --from-literal=password='<choose-a-strong-password>'
```

Create this **before** the app syncs (or the pod stays in `CreateContainerConfigError`).

## No DNS loop (unlike AdGuard)

Upstream resolution uses `DNS_SERVER_FORWARDERS=1.1.1.1, 8.8.8.8` over plain
TCP by IP, so Technitium never queries the pod's CoreDNS resolver. Recursion is
limited to private networks. This sidesteps the private-PTR feedback loop that
made AdGuard flood i/o-timeout errors.

## Bootstrap env vars

Set in `deployment.yaml` and applied on container start (further tuning is done
in the UI and persisted to the PVC):

- `DNS_SERVER_RECURSION=AllowOnlyForPrivateNetworks`
- `DNS_SERVER_ENABLE_BLOCKING=true` + a StevenBlack blocklist
- `DNS_SERVER_WEB_SERVICE_HTTP_PORT=5380`

## Cutover from AdGuard

1. Create the `technitium-admin` secret and let ArgoCD sync the app.
2. Confirm the pod is Ready and `192.168.178.249` answers:
   `dig @192.168.178.249 example.com` and `dig @192.168.178.249 -x 192.168.178.1`.
3. Log in at `https://technitium.jef.app` and finish configuration (blocklists,
   local zones, DHCP-advertised clients, etc.).
4. Point your router/DHCP DNS option at `192.168.178.249` and verify clients.
5. Once stable, remove the AdGuard app and free `192.168.178.250`.

## Internal DNS records via external-dns (RFC2136)

`external-dns` publishes `*.jef.app` records for gateway HTTPRoutes into Technitium
using **RFC2136 dynamic updates** (TSIG-secured), giving split-horizon DNS: LAN
clients resolve `*.jef.app` to the gateway LB IP `192.168.178.224`, while the
public/cloudflare side is untouched.

One-time Technitium setup (web console -> after first login):

1. **Create the zone.** Zones -> Add Zone -> `jef.app`, type **Primary**.
2. **Create a TSIG key.** Settings -> TSIG -> Add:
   - Key Name: `externaldns`
   - Algorithm: `HMAC-SHA256`
   - Shared Secret: click generate; copy the base64 value.
3. **Allow dynamic updates.** Zones -> `jef.app` -> Options -> Dynamic Updates:
   set to **Allow (using TSIG)** and add the `externaldns` key (leave network ACL
   empty / any).
4. **Allow zone transfer (AXFR).** Same Options dialog -> Zone Transfer: **Allow
   (using TSIG)** and add the `externaldns` key (external-dns lists records via
   `--rfc2136-tsig-axfr`).

Then create the TSIG secret in the `external-dns` namespace (kept out of git):

```sh
kubectl -n external-dns create secret generic technitium-rfc2136 \
  --from-literal=tsig-secret='<base64-shared-secret-from-step-2>'
```

The external-dns config lives in `apps/external-dns/base/values.yaml` (provider
`rfc2136`, host `technitium-dns.technitium.svc.cluster.local:53`, zone `jef.app`,
key `externaldns`, alg `hmac-sha256`). After ArgoCD syncs and the secret exists,
verify from a LAN client:

```sh
dig @192.168.178.249 grafana.jef.app    # -> 192.168.178.224 (gateway)
```

> Because `jef.app` becomes a Primary (authoritative) zone on Technitium, any
> `*.jef.app` name NOT managed by external-dns returns NXDOMAIN to LAN clients.
> That's the intended split-horizon behaviour for an internally-managed domain.

## Notes

- The Deployment sets **no CPU limit** (only a memory limit) on purpose: DNS is
  latency-sensitive and CPU limits cause CFS throttling — the alert we saw on
  AdGuard. It requests `100m` CPU / `256Mi` and is capped at `512Mi` memory.
- `strategy: Recreate` because the config PVC is `ReadWriteOnce`.
