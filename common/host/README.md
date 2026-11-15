# Host-level files (not Kubernetes manifests)

Installed directly on the node (`server1.chatflowpro.live`, 159.198.32.218) as root.

| File | Installed at | Purpose |
|------|--------------|---------|
| `xo-cf-origin-fw` | `/usr/local/sbin/xo-cf-origin-fw` | Allow TCP 443 and 80 only from Cloudflare's IPv4 ranges (ports set by `PORTS` in `/etc/default/xo-cf-origin-fw`, default `443 80`); loopback always allowed (fetched from `https://api.cloudflare.com/client/v4/ips`) |
| `xo-cf-origin-fw.service` | `/etc/systemd/system/` | Runs `apply` at boot (enabled) |
| `xo-cf-origin-fw.timer` | `/etc/systemd/system/` | Re-runs `apply` daily to pick up Cloudflare range changes (enabled) |

Install or update:

```bash
scp common/host/xo-cf-origin-fw root@159.198.32.218:/usr/local/sbin/
scp common/host/xo-cf-origin-fw.{service,timer} root@159.198.32.218:/etc/systemd/system/
ssh root@159.198.32.218 'chmod 755 /usr/local/sbin/xo-cf-origin-fw && systemctl daemon-reload \
  && systemd-run --on-active=5min --unit=xo-cf-deadman /usr/local/sbin/xo-cf-origin-fw rollback \
  && /usr/local/sbin/xo-cf-origin-fw apply'
# verify (proxied hosts 200 through Cloudflare, direct curl --resolve to the node on 443 times out), then:
ssh root@159.198.32.218 'systemctl stop xo-cf-deadman.timer'
```

Rollback: `ssh root@159.198.32.218 '/usr/local/sbin/xo-cf-origin-fw rollback && systemctl disable --now xo-cf-origin-fw.timer xo-cf-origin-fw.service'`.
The pre-change ruleset is saved on the node at `/root/iptables-before-xo-cf-origin-fw.rules`.

Ports 22, 6443, 10250 and all others are not touched.

**Loopback must stay allowed.** The tls-terminator proxies decrypted 443 traffic to envoy at `127.0.0.1:80`; the chain's first rule is `-i lo -j ACCEPT`. Without it every xoffice host times out (this happened for about 3 minutes on 2026-11-15 and was rolled back). If a new hostname is ever pointed at this node DNS-only (grey cloud) on 443, it will time out: proxy it, or add its clients to the script.
