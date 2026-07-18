# AX Svr — NAS (Samba Source Store)

The NAS (`nas`, LAN `10.1.1.97`) has exactly **one job**: hold the canonical web source/build artifacts and serve them over Samba (SMB) to the two IIS boxes on the LAN. It is deliberately *not* a web host and *not* a database backup repository — both of those roles were considered and rejected (see **Key decisions** below). The production pattern is **deploy-to-local**: each release, the current build is synced from the NAS down to local disk (`D:\app`) on `ax-web01` and `ax-web02`, and IIS serves from that local copy — never from the NAS share directly.

> **Source:** `docs/axsvr-phase2-nas.md` — **Status:** Production deployed.

![Deploy-to-local](../images/en/axsvr-web-deploy.png)
*(Operator note: upload this PNG as a page attachment in Confluence — it is shared with the Web / IIS page and produced separately.)*

---

## 1. Role and network

| Item | Value |
|---|---|
| Hostname | `nas` |
| OS | Ubuntu Server 24.04 |
| WAN IP | `107.118.210.97` |
| LAN IP | `10.1.1.97` |
| Role | Source/artifact store for web, served over Samba (SMB3), LAN-only |
| Source directory | `/srv/web-source` |
| Samba user | `webdeploy` (dedicated, not a login/system user) |
| Consumers | `ax-web01` (`10.1.1.101`), `ax-web02` (`10.1.1.102`) |
| NOT | A web host (IIS never runs off the NAS share) |
| NOT | A database backup repository (DB backup lives on `/backup` of `ax-db03` — Plan B, see the Backup page) |

---

## 2. Key decisions

**NAS = source store only, one role.** Everything below exists to serve that single purpose: hold source, hand it to the two web boxes over SMB. Nothing else is layered on this host.

**Why IIS does NOT run directly off the NAS (deploy-to-local, not UNC):**

Two models were evaluated:

| | Model A — Deploy-to-local (chosen) | Model B — IIS points at UNC (rejected) |
|---|---|---|
| IIS physical path | `D:\app` (local disk) | `\\10.1.1.97\web-source` (UNC) |
| NAS down | Web **keeps running** (already running the local copy) | Web **goes down** — NAS is a single point of failure |
| Performance | Local disk read, no SMB round trip per request | Slower — every request reads over SMB |
| Permissions | Simple (local filesystem) | Complex — App Pool identity must have rights on the remote share |
| Cost | Requires a deploy/sync step (one `robocopy` command or CI/CD) | None — update once, both web servers see it immediately |

Model A was chosen specifically to remove the NAS as a runtime SPOF and avoid IIS-over-UNC file-lock/permission issues. The NAS only needs to be up **at deploy time**, not while serving traffic.

**Why the NAS is NOT used for DB backups:** its only job is source distribution; overloading it with the DB backup repository would mix two unrelated failure domains and capacity/retention policies onto one box. DB backups (pgBackRest + `pg_dump`) live on a dedicated disk (`/backup`) on `ax-db03` instead (Plan B — see the Backup page). The NAS's own source tree still needs *its own* backup (see §6) — that is a separate, much smaller concern from DB backup.

---

## 3. Create the Samba user and source directory (on the NAS)

```bash
sudo mkdir -p /srv/web-source
sudo groupadd webdeploy
sudo useradd -M -s /usr/sbin/nologin -g webdeploy webdeploy
sudo chown -R webdeploy:webdeploy /srv/web-source
sudo chmod -R 2775 /srv/web-source       # setgid so new files keep the group

# Samba password for webdeploy (separate from any system password):
sudo smbpasswd -a webdeploy
```

---

## 4. Samba configuration (LAN only)

Append to `/etc/samba/smb.conf`:

```ini
[global]
   # Listen on the LAN NIC only — never expose Samba on WAN
   interfaces = 10.1.1.97/24
   bind interfaces only = yes
   server min protocol = SMB3
   # Only the two web servers (+ localhost) may connect
   hosts allow = 10.1.1.101 10.1.1.102 127.0.0.1
   hosts deny = 0.0.0.0/0

[web-source]
   path = /srv/web-source
   browseable = yes
   read only = no
   valid users = webdeploy
   create mask = 0664
   directory mask = 2775
   force group = webdeploy
```

Validate and start:
```bash
sudo testparm                       # check syntax
sudo systemctl enable --now smbd nmbd
```

**Firewall — open Samba to the LAN only:**
```bash
sudo ufw allow from 10.1.1.0/24 to any port 445 proto tcp
sudo ufw allow from 10.1.1.0/24 to any port 139 proto tcp
```

---

## 5. Deploy: NAS → local on both web servers (manual, per release — no CI/CD yet)

> No CI/CD exists yet, so deploy happens **per release**, **NOT on a periodic cron**. Every release pushes **both** web servers from the **same** build on the NAS, so the two stay identical. IIS always runs from local disk (`D:\app`); the NAS only needs to be reachable during the deploy step.

### Release workflow
```
1. Web engineer builds the app (e.g. React build)          → produces a build directory
2. Upload the build to the NAS under a VERSION folder, e.g. /srv/web-source/2025-07-01
   then point "current" at the new version (keeps rollback easy)
3. On ax-web01 AND ax-web02: run deploy.ps1                 → pulls "current" down to D:\app
4. Verify: health check on both web servers + access via the proxy VIP
```

Point `current` at the new version on the NAS (rollback = point back to the old version, then redeploy):
```bash
ln -sfn /srv/web-source/2025-07-01 /srv/web-source/current
```

### Save the NAS credential once per web server (so it isn't re-entered each time)
```powershell
cmdkey /add:10.1.1.97 /user:webdeploy /pass
```

### `deploy.ps1` — run on EACH web server (`ax-web01`, `ax-web02`) at release time
```powershell
param(
  [string]$Src  = "\\10.1.1.97\web-source\current",
  [string]$Dst  = "D:\app",
  [string]$Pool = "AXPool"
)
Import-Module WebAdministration
robocopy $Src $Dst /MIR /R:2 /W:2 /NFL /NDL /NP
if ($LASTEXITCODE -ge 8) { Write-Error "robocopy failed ($LASTEXITCODE)"; exit 1 }
Restart-WebAppPool -Name $Pool          # load the new build (lighter than iisreset)
Write-Host "Deploy finished on $env:COMPUTERNAME"
```
> **Why `robocopy` is still fine here:** it runs **at release time, manually** — not on a cron — so there is no drift or staleness risk. `/MIR` guarantees local matches the NAS exactly. Exit codes 0–7 = OK, ≥8 = error.

### Optional: push both web servers with a single command (from an admin machine)
```powershell
# Admin machine reads from the NAS and writes straight into D:\app on both web servers (via the d$ admin share)
"\\10.1.1.101\d$\app","\\10.1.1.102\d$\app" | ForEach-Object {
  robocopy "\\10.1.1.97\web-source\current" $_ /MIR /R:2 /W:2 /NP
}
# then recycle the app pool on each web server (RDP or PowerShell Remoting)
```
> Requires SMB(445) open from the admin machine to both web servers, plus admin rights. More convenient, but more setup — if in doubt, just run `deploy.ps1` on each web server.

**IIS site:** physical path = `D:\app` (local), **NOT** a UNC path.
**Do NOT** set up a periodic cron `robocopy` job — sync happens only at RELEASE time.

---

## 6. Load-balancing note (the two web servers must stay identical)

Since Nginx (the proxy tier) round-robins/least-conn's traffic across both web servers, **the two must be kept in sync**:

1. **Same source always:** always deploy `ax-web01` **and** `ax-web02` from the same NAS build — never deploy them separately from different versions.
2. **Session/state:** if the app has session state, either use **sticky sessions** (Nginx `ip_hash` / cookie) or a **shared session store** (Redis/DB) — coordinate with the web engineer. A static React build is usually stateless, but a backend API needs this considered.
3. **User uploads:** if the app accepts uploads, do **not** store them on each web server's local disk (they'd diverge) — use a shared NAS share or object storage instead.

---

## 7. Backing up the NAS's own source

The source tree itself still needs backing up — if the NAS dies, un-committed source is lost:
```bash
# Example: periodic snapshot of the source tree to another location (cron, on the NAS)
0 2 * * * tar czf /srv/backup/web-source-$(date +\%F).tgz -C /srv web-source
```
> Better long-term: keep source in a **git repo** (NAS holds only the build artifact) — gives history and easy restore.

This is a small, separate concern from DB backup — see the **Key decisions** note above: the NAS is not, and should not become, the DB backup repository.

---

## 8. Checklist

- [ ] `/srv/web-source` + user `webdeploy` created (kept separate from `pgbackrest`/DB accounts)
- [ ] Samba listens on LAN only, `hosts allow` matches exactly the two web servers
- [ ] Firewall opens 445/139 to the LAN only
- [ ] Web servers can map the share (`cmdkey` credential saved), `deploy.ps1` runs OK
- [ ] IIS physical path = **`D:\app` (local)**, not UNC
- [ ] Deploy happens **per release** (both web servers from the same build), **no periodic cron**
- [ ] NAS source is **versioned** with a `current` symlink for rollback
- [ ] Session/upload handling agreed with the web engineer
- [ ] The NAS's own source tree is backed up

---

## Related pages

- AX Svr — Web / IIS (`03-web.md`)
- AX Svr — Proxy HA (`04-proxy.md`)
- AX Svr — Database HA (`02-db.md`)
- AX Svr — Backup (`06-backup.md`)

---

Paste as Markdown; upload any referenced PNG as a page attachment.
