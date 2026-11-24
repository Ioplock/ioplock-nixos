# Traefik on mimosa — how it works

Traefik runs as a **system service** on the NixOS side (`services.traefik`)
and watches the **rootful docker daemon** (`/run/docker.sock`) for containers
with traefik labels. Any compose stack you bring up with the right labels is
exposed automatically.

```
internet ──► router (forwards TCP 80 + 443) ──► mimosa ──► Traefik ──► docker containers
                                              │
LAN PC ────────────────────────────────────────┤► dashboard http://<mimosa-ip>:8080/
                                               └► direct ports (qBittorrent 8085, netdata 19999, …)
```

## What is where

| Thing | Config |
|---|---|
| Traefik feature (NixOS service, entrypoints, ACME, firewall) | `modules/features/traefik.nix` |
| Docker feature (rootless vs rootful mode) | `modules/features/docker.nix` |
| Host wiring (rootful docker, docker group, ports) | `modules/hosts/mimosa/configuration.nix` |

## Requirements for it to work

1. **Router port forwarding** — forward TCP **80** and **443** to mimosa.
   Port 80 is used by Let's Encrypt (HTTP-01 challenge) and by the
   HTTP→HTTPS redirect; 443 serves the actual TLS traffic. Do **not**
   forward 8080.
2. **DNS** — an A record pointing to your public IP, per service:
   `plane.ioplock.su`, `app2.ioplock.su`, …
3. **Labels on the compose service** — see below.

Certificates are issued automatically by Let's Encrypt the moment a
container with a matching `Host()` label appears.

## Labels for a compose stack (minimal)

```yaml
services:
  plane:
    image: ...
    labels:
      - traefik.enable=true
      - traefik.http.routers.plane.rule=Host(`plane.ioplock.su`)
```

That is all. Then:

```bash
docker compose up -d
```

Details:

- **Do not add a `tls` label** (e.g. `traefik.http.routers.plane.tls=true`).
  The websecure entrypoint already enables TLS + the ACME resolver for every
  router; a router-level `tls` section *replaces* that default entirely and
  certificates stop being requested automatically.
- No `entrypoints` label needed: the router attaches to both entrypoints —
  plain HTTP gets permanently redirected to HTTPS.
- If the image exposes several ports (or none), tell Traefik which port to
  route to:
  ```yaml
  - traefik.http.services.plane.loadbalancer.server.port=8080
  ```
- Container must be reachable from the host bridge network — normal for any
  container that actually listens on its internal port.

## Dashboard

`http://<mimosa-ip>:8080/dashboard/` — mimosa itself or any LAN PC.
It is only reachable on the LAN because the router does not forward 8080.

## Existing services

qBittorrent (`:8085`) and netdata (`:19999`) are intended for LAN use and
stay on their direct ports — they are not routed through Traefik.

## NixOS-side notes

- mimosa runs **rootful docker** (`myDocker.mode = "rootful"`) because the
  Traefik system user can only access the rootful socket; rootless
  (`/run/user/<uid>/docker.sock`) is forbidden to it. The `mimosa` user is
  in the `docker` group, so plain `docker compose` works without sudo.
- One-time migration: containers/images from the old rootless daemon are
  not carried over — `docker compose up -d` your stacks again once after
  the switch (images re-pull), and re-login so the `docker` group applies.
- Config options (`myTraefik.*`) live in `modules/features/traefik.nix`:
  firewall, dashboard, ACME email, `exposedByDefault`, shared docker
  network.
- Verify changes only:
  ```bash
  nix flake check
  nixos-rebuild dry-build --flake .#mimosa
  ```
  Activation (switch/boot) is done by the user.
