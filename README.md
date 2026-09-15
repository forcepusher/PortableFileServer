# PortableFileServer

Read-only HTTP file server. No login. Hosts the `PublicFiles` folder next to this directory.

```
parent/
  PublicFiles/          <-- put files here
  PortableFileServer/
    LaunchFileServer.bat
```

## Start

1. Create `PublicFiles` one level above this folder if it is not there already.
2. Put the files you want to share in `PublicFiles`.
3. Double-click `LaunchFileServer.bat`.
4. Open `http://localhost:8080/`.

Close the window or press Ctrl+C to stop.

If `PublicFiles` is missing, the launcher prints an error and exits.

## Reach it from other machines

The launcher does not change Windows Firewall, port forwarding, or anything else on the PC.

For LAN access, allow inbound TCP port **8080** in Windows Firewall, then use `http://YOUR-LAN-IP:8080/`.

For the public internet, you also need to forward TCP 8080 (or put a reverse proxy / tunnel in front) to this machine. HTTPS is strongly recommended if you expose it past your LAN.

## Notes

- Sharing is list + download only. Visitors cannot upload, edit, or delete.
- Default listen port is 8080 (`PFS_HTTP_PORT` in `LaunchFileServer.bat`).
- This package uses [SFTPGo](https://github.com/drakkan/sftpgo).
