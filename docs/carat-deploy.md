# Carat CD on mimosa - how it works

GitHub Actions builds `ghcr.io/carat-team/carat-backend:latest` on every push
to `master` in `carat-team/carat`, then signals mimosa over SSH. The signal
can do exactly one thing: run `docker compose pull` + `up -d` for the stack in
`/etc/carat`. Nothing else is reachable from CI.

```
release.yml (build-latest -> deploy job)
  ssh -p 9922 carat-ci@78.107.234.81
      |
      | authorized_keys: restrict,command="<signal>"
      | (forced command: no shell, no pty, no forwarding, no arguments)
      v
  carat-deploy-signal        (runs as carat-ci)
      sudo -n <trigger>      <- sudo rule: exact store path, NOPASSWD, only rule
      v
  carat-deploy-trigger       (runs as root)
      systemctl start carat-deploy.service
      v
  carat-deploy.service       (oneshot, root, requires docker.service)
      cd /etc/carat && docker-compose pull && up -d && ps
      v
  traefik sees the labels -> carat.ioplock.su (ACME HTTP-01) -> backend:8080
```

## What is where

| Thing | Config |
|---|---|
| Feature module (user, sudo rule, unit, limits) | `modules/features/carat-deploy.nix` |
| Enabled + keys + caps | `modules/hosts/mimosa/configuration.nix` (`myCaratDeploy`) |
| Prod stack + `.env` | server: `/etc/carat/` (0700, root-owned, outside any repo) |
| Stack data (hard 10G cap) | server: `/var/lib/carat/data.img` loop fs mounted at `/var/lib/carat/data` |
| Deploy key (private) | GitHub secret `CARAT_DEPLOY_KEY` in `carat-team/carat` |
| GHCR pull credentials | server: `/root/.docker/config.json` (PAT, scope `read:packages`) |
| Trigger job | `carat-team/carat` -> `.github/workflows/release.yml`, job `deploy` |

## Resource limits (hard caps)

| Resource | Mechanism | Value (mimosa) |
|---|---|---|
| RAM | `carat.slice` with `MemoryHigh`/`MemoryMax`; every compose service sets `cgroup_parent: carat.slice` | throttle at 4G, OOM-kill at 6G for the whole stack |
| Data disk | fixed-size loop ext4 image created by `install.sh`, mounted by a NixOS `fileSystems` entry (`loop,nofail`); postgres and S3 live inside it | 10G ceiling (`CARAT_DATA_SIZE` at install time) |
| Image disk | weekly `carat-gc.timer` -> `docker image prune --all --filter until=168h` (old `:latest` layers from deploys; running containers are never touched) | soft, typically a few GB |

The slice exists only after the `myCaratDeploy` module is switched in, so
`install.sh` refuses to start the stack before that and tells you to switch
first. CPU is not limited.

## Security properties

1. The CI key is bound with `restrict,command=` in `carat-ci`'s authorized
   keys. sshd runs only the forced command; `SSH_ORIGINAL_COMMAND` is never
   read; port/agent forwarding, pty and user rc files are disabled.
2. `carat-ci` is a system user (home `/var/empty`), not in `wheel`, not in
   the `docker` group. Its entire privilege set is one NOPASSWD sudo rule
   naming a single store path with no arguments.
3. The scripts are Nix derivations from this flake - the repository cannot
   change what runs on the server.
4. The repository is not cloned on the server. CI only influences image
   content; mounts, networks and privileges live in root-owned
   `/etc/carat/docker-compose.yml`.
5. `.env` (DB/S3 passwords) is generated on the server by `install.sh` and
   never enters git or this flake.

## Routing (single domain, no CORS)

- `Host(carat.ioplock.su)` + `PathPrefix(/api, /health, /docs, /openapi.json,
  /redoc)` -> backend container, port 8080, priority 10.
- Everything else on that host: redirect `/` -> `/docs` (FastAPI Swagger),
  priority 1. When the frontend gets containerized, the catch-all router is
  repointed to the frontend service.
- Do not add `tls` labels: the websecure entrypoint already attaches the
  letsencrypt resolver (see `docs/traefik.md`).

## Verification

```bash
# unit log (deploy output also lands in the CI job log)
journalctl -u carat-deploy -n 80

# stack state
cd /etc/carat && sudo docker-compose ps

# limits are actually enforced
systemctl show carat.slice -p MemoryHigh -p MemoryMax
df -h /var/lib/carat/data
cat /proc/$(sudo docker inspect -f '{{.State.Pid}}' carat-backend)/cgroup
systemctl list-timers carat-gc.timer --no-pager

# from outside
curl -fsS https://carat.ioplock.su/health     # {"status":"ok"}
curl -sI https://carat.ioplock.su/            # redirect to /docs

# isolation tests: every one of these must NOT run the command you typed
ssh -p 9922 carat-ci@78.107.234.81 id
ssh -p 9922 carat-ci@78.107.234.81 sudo -l
ssh -p 9922 carat-ci@78.107.234.81 docker ps
ssh -p 9922 -N -L 9999:localhost:22 carat-ci@78.107.234.81   # refused
```

Verification of flake changes only (never switch from an agent):

```bash
nix flake check
nixos-rebuild dry-build --flake .#mimosa
```

## Rotation

- **Deploy key**: generate a new ed25519 pair, put the public key into
  `myCaratDeploy.deployPublicKey`, the private key into the GitHub secret,
  rebuild/switch, then delete the old private key file.
- **GHCR PAT**: expires -> `deploy` job fails at `docker-compose pull`.
  Create a new classic PAT with `read:packages`, then on the server:
  `sudo docker login ghcr.io -u <user>` (writes `/root/.docker/config.json`).

## Rollback

Images are immutable; `:latest` only moves forward. To roll back: on the
server as root, `docker-compose up` with a previously pulled image tag or
re-tag an old image, then fix the cause in git. Data lives in the named
volumes `postgres_data` and `s3_data` and survives restarts.
