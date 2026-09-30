# qBittorrent — save path permissions

The `qbittorrent` service runs as the dedicated system user
`qbittorrent:qbittorrent`, not as your login user. Any download directory
outside its own state dir (`/var/lib/qBittorrent/Downloads`) must be
explicitly writable by that user.

## Symptom

A torrent sits in state **error**, 0 pieces, with no obvious reason in
`journalctl -u qbittorrent`. The real cause is in the WebUI log:

```bash
curl -sS 'http://127.0.0.1:8085/api/v2/log/main?last_known_id=0' | jq '.[].message'
```

```
File error alert. Torrent: "..." File: "/mnt/disk0/games/.../climates.zip".
Reason: "file_open (...): error: Permission denied"
```

## Fix

Grant the service user write access to the save directory. On mimosa
(`/mnt/disk0` is ext4, ACLs work):

```bash
ssh mimosa@192.168.1.92
setfacl -m u:qbittorrent:rwx /mnt/disk0/games
getfacl /mnt/disk0/games   # verify: user:qbittorrent:rwx
```

Then resume the torrent in the WebUI (or `POST /api/v2/torrents/start`).
The torrent subdirectory is created by the service and owned by it
afterwards; only the parent directory needs the ACL.

A plain `chmod o+w` would work too but opens the directory to every local
user — prefer the ACL.

## Why not in the flake?

The grant is host-specific file ownership on a data disk, not declarative
system state. If the disk is ever re-formatted or the save path changes,
re-run the `setfacl` line above.
