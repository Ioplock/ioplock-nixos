# Handoff: Cloudflare:443 dies through the sing-box TUN (zapret double pass)

- Date: 2026-11-25 (night), Europe/Moscow.
- Host: `mimosa` (NixOS, Linux 6.18.54).
- Status: **blocking CD for `carat-team/carat`** - traefik cannot reach
  `acme-v02.api.letsencrypt.org` (Cloudflare-hosted) and therefore cannot
  issue the Let's Encrypt certificate for `carat.ioplock.su`.
- Cross-reference: full diagnostic handoff in the private strategies repo
  `zapret-cfg` -> `docs/reports/2026-11-25-handoff-mimosa-cloudflare-443.md`
  (Russian). Verdict there: **strategies are NOT the culprit**, do not change
  `zapret-cfg`.

## What is broken

All HTTPS/TCP-443 connections from mimosa to destinations matched by the
zapret strategies **and** routed through the sing-box TUN time out after the
ClientHello. Direct (non-TUN) traffic is fine, and the TUN path without
zapret is fine for the CD-critical hosts.

## A/B test results (2026-11-25 ~03:30, script `/home/mimosa/cf-ab-test.sh`,
source `server-host-thing/diag-cf-ab.sh`, raw output `/tmp/cf-ab-result.txt`)

| Phase | www.cloudflare.com | acme-v02.../directory | auth.docker.io/token | ghcr.io/v2 |
|---|---|---|---|---|
| 0. baseline (both on) | FAIL(rc=28) | FAIL | FAIL | 401 |
| 1. sing-box **stopped** (no TUN, zapret on) | **200** | **200** | **200** | 401 |
| 2. nfqws2 **stopped** (TUN on, zapret off) | FAIL(rc=28) | **200** | **200** | 401 |
| 3. both stopped (network control) | **200** | **200** | **200** | 401 |
| 4. restored (both on) | FAIL | FAIL | FAIL | 401 |

Conclusions:

- Failure requires **both** zapret2 and the TUN: H1 (interaction) confirmed.
- zapret strategies on a plain kernel path are healthy (phase 1 == acrux
  behaviour): H3 rejected.
- `queue flags bypass` in the nft rules + phase 2 successes: H4 (queue with
  no listener) rejected.
- Anomaly to re-check: `www.cloudflare.com` still failed in phase 2 (single
  sample, zapret off). Not CD-critical (LE works in phase 2), but re-run
  phase 2 before drawing conclusions - it may be an independent TUN/gvisor
  issue.

## Mechanism (from the live nft table, phase 2 output)

```
table inet zapret2 {
  chain post {
    type filter hook postrouting priority srcnat + 1; policy accept;
    ip daddr @local4 accept
    ... tcp dport { 80, 443, 2053, 2083, 2087, 2096, 8443 } ct original packets 1-12 queue flags bypass to 200
    ... meta l4proto udp ct original packets 1-12 queue flags bypass to 200
  }
  chain pre {
    type filter hook prerouting priority dstnat - 1; policy accept;
    ... tcp sport { 80, 443, ... } ct reply packets 1-12 queue flags bypass to 200
    ...
  }
  chain predefrag { hook output priority -401; meta mark & 0x40000000 != 0 notrack }
}
```

The queue rules are **not bound to any interface**, and `postrouting` runs
for packets entering `tun0` as well. A TUN-routed flow therefore passes
nfqws2 **twice**:

1. the client's packet (oif = tun0) is desynchronized and delivered into the
   **gvisor userspace stack** of sing-box (fakes with bogus seq/`tcp_md5`
   and mid-stream splits land in a userspace TCP state machine, not on a
   wire where they would be discarded);
2. sing-box re-originates the connection from its own process (oif =
   enp5s0), which is queued and desynchronized **again** on the real wire;
   replies are likewise mangled on both ingress legs (`pre` chain).

On acrux (no TUN, sing-box in socks mode only) the same strategies run a
single pass and everything works - phase 1 on mimosa reproduces this.

Relevant configs in this flake:

- `modules/features/modio-split.nix` - TUN inbound (`auto_route`,
  `strict_route`, `stack = "gvisor"`, MTU 9000) and the route rules
  (`sniff` -> mod.io -> `proxy` -> catch-all `inbound=tun -> direct`).
  Almost all host traffic enters tun0 because of auto_route.
- `modules/features/sing-box.nix` - base rules, `final = "proxy"`.
- `modules/features/zapret.nix` - `services.zapret2` (upstream module,
  `configureAutomatically` generates the nft rules above), sops strategies,
  `myNfqws2` wrapper.

## Fix options (ranked)

1. **nft: stop queueing tun0 traffic** - the true fix. Exclude flows that
   egress/ingress via `tun0` from the queue rules so each connection is
   desynchronized exactly once, on the wire. Investigation needed: the
   rules come from the upstream `services.zapret2` module
   (`configureAutomatically`), so check what it exposes for overrides
   (or set it to false and ship an equivalent table via
   `networking.nftables` from `modules/features/zapret.nix`).
   Note the reply direction (`pre` chain) is equally problematic for TUN
   flows - both legs must be considered.
   Hard constraints (from `zapret-cfg` AGENTS.md): never
   `nft flush ruleset`, never delete foreign tables, do not modify the
   strategies themselves.
2. **sing-box route rule: send the CD domains via the `proxy` outbound** -
   smallest change that unblocks CD. The wire destination then becomes the
   proxy node IP, which is not in zapret's ipset/hostlist, so nfqws passes
   it unmodified (proven: all socks tests returned 200). Placement is the
   tricky part: the rule must evaluate **after** `action = "sniff"` and
   **before** modio-split's `inbound = tun -> direct` catch-all. Currently
   both are `lib.mkBefore` blocks from two modules; a deterministic order
   needs explicit `lib.mkOrder` on the rule groups across
   `modio-split.nix` and `sing-box.nix`. Scope: only fixes CD, the general
   double-pass for other Cloudflare sites remains.
3. **fwmark-based skip** - mark sing-box-originated packets so zapret skips
   them (the `predefrag` chain already special-cases
   `meta mark & 0x40000000`), but that mark belongs to zapret itself -
   coordinate before reusing it.

A good sequence: option 2 for the immediate CD unblock, then option 1 as
the proper fix; verify with the A/B script after each step.

## How to verify

```sh
# on mimosa, no sudo needed for the probes
for u in https://www.cloudflare.com/ \
         https://acme-v02.api.letsencrypt.org/directory \
         https://auth.docker.io/token \
         https://ghcr.io/v2/; do
  curl -4 -sS --noproxy='*' -o /dev/null \
    -w "$u -> %{http_code} conn=%{time_connect}\n" --max-time 12 "$u"
done
```

- Full A/B matrix: `sudo bash /home/mimosa/cf-ab-test.sh` (stops and
  restores both services; interrupts active connections - not during a call).
- Isolation of individual nft legs (root, temporary, diagnosis only):
  `nft flush chain inet zapret2 post` / `nft flush chain inet zapret2 pre`
  - restore by restarting `nfqws2@default`. Do not flush anything else.
- Log: `journalctl -u nfqws2@default -n 100`.

**Criterion of done:** with both `sing-box` and `nfqws2@default` running,
the three URLs above return 200 in three consecutive runs; then re-trigger
traefik ACME (restart `traefik.service`) and confirm a valid Let's Encrypt
certificate for `carat.ioplock.su:8443`. CD (job `deploy` in the carat
repo) is still unpushed and will be finished by the CD agent after this
criterion passes.

## Boundaries

- Strategies, lists and blobs live in `zapret-cfg` (private, sops-imported
  via `nix run .#myZapretImport`) - **not to be changed for this issue**
  (proven healthy in phase 1). `secrets/zapret.json` must never be edited by
  hand.
- `nixos-rebuild switch` is performed by the user, never by an agent.
- Current server state: carat stack (docker compose in `/etc/carat`) is up
  and healthy behind traefik, serving the default self-signed certificate
  until ACME succeeds; external HTTPS port on this host is **8443**
  (the provider blocks inbound 443).
