# Windows Server Handoff — Part-DB (UW-Madison)

**Audience:** AI coding agents (Grok, Claude, Cursor, Codex, etc.) and humans restoring this stack on a **Windows** machine with Docker Desktop.

**Goal:** Clone this backup, rebuild Part-DB, and run it so inventory (including **Luke's Components** and **Abhinav's Components**) is available at `http://localhost:8080`.

This repo is a **private** full deployment backup. Treat `secrets.env` and `db/app.db` as sensitive.

---

## 0. Success criteria (definition of done)

When finished, all of the following must be true:

| Check | Expected |
|-------|----------|
| Container running | `docker ps` shows `partdb` **Up** |
| HTTP | `http://localhost:8080` returns **200**, page title contains `Part-DB` |
| Data volumes mounted | `./db`, `./uploads`, `./public_media` exist next to `docker-compose.yaml` |
| Inventory tags | Parts searchable by tag **`Luke's Components`** and **`Abhinav's Components`** |
| Login | User **`Abhinav`** can sign in (password already set in DB; reset via console if unknown) |

---

## 1. Prerequisites (host)

Install and verify **before** cloning:

1. **Windows 10/11** or Windows Server with admin rights for Docker.
2. **Git for Windows** (`git --version`).
3. **Docker Desktop** with Linux containers enabled.
4. **PowerShell 5.1+** (built-in) or PowerShell 7.

Verify:

```powershell
git --version
docker --version
docker compose version
# Docker engine must be running (Docker Desktop tray icon green)
docker info
```

If `docker info` fails, start Docker Desktop and wait until it is fully up.

**Disk:** first image build can pull ~1–2+ GB. Allow **10–20 minutes** for the initial `docker compose up --build`.

**Network:** outbound HTTPS required (Docker Hub, DigiKey API if re-linking parts).

---

## 2. Choose install directory

Recommended on a server:

```powershell
# Example — change to suit the machine
$InstallRoot = "C:\PartDB"
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
Set-Location $InstallRoot
```

All following commands assume the current directory is the **deployment root** (the folder that will contain `docker-compose.yaml`).

---

## 3. Clone this backup repo

```powershell
git clone https://github.com/abhinav937/PartDB-UW-madison.git .
# If the folder is not empty, clone into a subfolder instead:
# git clone https://github.com/abhinav937/PartDB-UW-madison.git PartDB
# Set-Location PartDB
```

Confirm critical files exist:

```powershell
@(
  "docker-compose.yaml",
  "secrets.env",
  "db\app.db",
  "public_media",
  "RESTORE.md",
  "AGENT_INSTALL.md"
) | ForEach-Object {
  if (-not (Test-Path $_)) { throw "Missing required path: $_" }
  Write-Host "OK $_"
}
```

Create empty folders Docker expects if missing:

```powershell
@("uploads") | ForEach-Object {
  if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ | Out-Null }
}
```

---

## 4. Clone Part-DB server source (required for Docker build)

`Part-DB-server/` is **not** stored in this repo (see `.gitignore`). It is a custom fork with barcode-scanner fixes. Build context in `docker-compose.yaml` is `./Part-DB-server`.

```powershell
git clone https://github.com/abhinav937/Part-DB-server.git Part-DB-server
Set-Location Part-DB-server
git remote add upstream https://github.com/Part-DB/Part-DB-server.git 2>$null
# Pin to the commit this deployment was validated against:
git checkout 148abe546be062a9a6a27fdca7f1c8fe98dbedf2
Set-Location ..
```

Verify:

```powershell
if (-not (Test-Path "Part-DB-server\Dockerfile")) {
  throw "Part-DB-server clone incomplete (Dockerfile missing)"
}
git -C Part-DB-server rev-parse HEAD
# Expect: 148abe546be062a9a6a27fdca7f1c8fe98dbedf2
```

---

## 5. Review secrets (do not commit changes lightly)

File: **`secrets.env`** (already in this private repo).

Contains:

- DigiKey Product Information API client id/secret (`PROVIDER_DIGIKEY_*`)
- Symfony `APP_SECRET`

Agents should **not** print full secrets into chat logs when avoidable. Do not push this repo to a public remote.

Optional env vars (only if changing host networking):

- Edit `docker-compose.yaml` port mapping if `8080` is taken: `"8080:80"` → e.g. `"8081:80"`.

---

## 6. Build and start Part-DB

From the directory that contains `docker-compose.yaml`:

```powershell
docker compose up -d --build
```

First build compiles PHP + frontend assets; expect **several minutes**. Subsequent starts are faster:

```powershell
docker compose up -d
```

Useful commands:

```powershell
docker compose ps
docker ps --filter name=partdb
docker logs partdb --tail 100
docker compose down          # stop
docker compose up -d --build # rebuild after Part-DB-server changes
```

---

## 7. Verify the app is healthy

```powershell
# Wait a few seconds after container start for PHP-FPM/Apache
Start-Sleep -Seconds 8
$r = Invoke-WebRequest -Uri "http://localhost:8080" -UseBasicParsing -TimeoutSec 30
if ($r.StatusCode -ne 200) { throw "Expected HTTP 200, got $($r.StatusCode)" }
if ($r.Content -notmatch "Part-DB") { throw "Page does not look like Part-DB" }
Write-Host "OK Part-DB is responding on http://localhost:8080"
```

Browser: open **http://localhost:8080**.

### 7.1 Users (from current DB)

| Username | Role | Notes |
|----------|------|--------|
| `Abhinav` | admin | Primary admin; email `chinnusamy@wisc.edu` |
| `anonymous` | readonly group | System anonymous user |

If the password is unknown, reset inside the container (run as `www-data` when possible):

```powershell
docker exec -u www-data -it partdb php bin/console partdb:users:set-password Abhinav --no-interaction
# If the console prompts about running as root, prefer -u www-data as above.
# Interactive password prompts: use -it and type when asked, or check command --help for non-interactive flags on this Part-DB version.
```

List users:

```powershell
docker exec -u www-data partdb php bin/console partdb:users:list --no-interaction
```

### 7.2 API token (for scripts)

Existing Edit-scope token is stored in SQLite table `api_tokens` (user Abhinav). Prefer creating a **new** token in the UI after login:

**User settings → API tokens → New token (scope: Edit)**

Then:

```powershell
$env:PARTDB_TOKEN = "tcp_..."   # paste new token
```

Scripts under `scripts\` expect `$env:PARTDB_TOKEN` or `-Token`.

---

## 8. Inventory tags (how to filter parts)

Parts are tagged for owner filtering in the Part-DB UI:

| Tag | Meaning |
|-----|---------|
| **Abhinav's Components** | Pre-existing / original inventory (~106 parts) |
| **Luke's Components** | Imported from combined GaN module CSV (~100 parts) |
| Both | Rare overlap (e.g. `5019`, `TSR 1-2450E`) |

In the UI: open parts list → filter/search by tag name.

Also present on Luke imports: `gan-module-rev3`, `csv-import-2026-06-01`.

---

## 9. DigiKey info provider (optional, post-install)

DigiKey **client id/secret** live in `secrets.env`. Full product search also needs a **user OAuth** token stored in DB table `oauth_tokens` (`ip_digikey_oauth`).

Access tokens **expire** (~30 minutes). Refresh tokens last longer but can invalidate if refreshed elsewhere without saving the new refresh token.

### 9.1 Preferred: reconnect via UI

1. Log in as admin.
2. Open Part-DB **info provider / DigiKey settings** (Tools → Info providers, or system settings depending on version).
3. Click **Connect / OAuth** for DigiKey and complete browser login on developer.digikey.com.

### 9.2 Agent-assisted refresh (when refresh token still valid)

```powershell
# Read refresh token from DB
$php = @'
<?php
$db = new PDO('sqlite:/var/www/html/var/db/app.db');
echo $db->query("SELECT refresh_token FROM oauth_tokens WHERE name='ip_digikey_oauth'")->fetchColumn();
'@
$php | docker exec -i -u www-data partdb tee /tmp/read_dk_refresh.php | Out-Null
$refresh = (docker exec -u www-data partdb php /tmp/read_dk_refresh.php).Trim()

# Load client credentials from secrets.env (do not echo them)
Get-Content .\secrets.env | ForEach-Object {
  if ($_ -match '^\s*PROVIDER_DIGIKEY_CLIENT_ID=(.+)$') { $clientId = $Matches[1].Trim() }
  if ($_ -match '^\s*PROVIDER_DIGIKEY_SECRET=(.+)$') { $clientSecret = $Matches[1].Trim() }
}

$tok = Invoke-RestMethod -Method POST -Uri "https://api.digikey.com/v1/oauth2/token" -Body @{
  client_id     = $clientId
  client_secret = $clientSecret
  refresh_token = $refresh
  grant_type    = "refresh_token"
} -ContentType "application/x-www-form-urlencoded"

$exp = (Get-Date).ToUniversalTime().AddSeconds([int]$tok.expires_in - 60).ToString("yyyy-MM-dd HH:mm:ss")
$php2 = @"
<?php
`$db = new PDO('sqlite:/var/www/html/var/db/app.db');
`$st = `$db->prepare("UPDATE oauth_tokens SET token = ?, refresh_token = ?, expires_at = ?, last_modified = datetime('now') WHERE name = 'ip_digikey_oauth'");
`$st->execute(['$($tok.access_token)', '$($tok.refresh_token)', '$exp']);
echo 'ok';
"@
$php2 | docker exec -i -u www-data partdb tee /tmp/save_dk_tokens.php | Out-Null
docker exec -u www-data partdb php /tmp/save_dk_tokens.php
```

If refresh returns `Invalid RefreshToken`, use **§9.1 UI reconnect**.

---

## 10. Optional: re-import Luke inventory from CSV

Only needed if the DB was wiped or you have a **new** CSV. Idempotent: safe to dry-run first.

Script: `scripts\import_csv_inventory.ps1`

Default CSV path (original laptop):

`C:\Users\abhin\Box\Abhinav\inventory-management-files\combined_components_inventory_6_01.csv`

On a new server, copy the CSV onto the machine and pass `-CsvPath`.

```powershell
$env:PARTDB_TOKEN = "tcp_..."   # Edit-scope token
cd scripts

# Dry run (no writes)
powershell -NoProfile -ExecutionPolicy Bypass -File .\import_csv_inventory.ps1 `
  -CsvPath "D:\path\to\combined_components_inventory_6_01.csv"

# Apply
powershell -NoProfile -ExecutionPolicy Bypass -File .\import_csv_inventory.ps1 `
  -CsvPath "D:\path\to\combined_components_inventory_6_01.csv" `
  -Apply
```

What the script does:

1. Aggregates unique MPNs and `on_hand` from the CSV.
2. Creates parts with tag **`Luke's Components`** (plus `gan-module-rev3`, `csv-import-2026-06-01`).
3. Creates stock lots (`GaN Module inventory …`).
4. Creates DigiKey orderdetails (real product URLs when DigiKey OAuth works; otherwise search URLs).
5. Maps categories (Capacitors, Resistors, MOSFET, etc.).

Related script (PCB barcodes, not Luke CSV):

- `scripts\import_ssmg_pcbs.ps1` + `scripts\codes.txt`

---

## 11. Directory layout (what must stay together)

```
<deploy-root>/
  docker-compose.yaml      # service definition, port 8080
  secrets.env              # DigiKey + APP_SECRET
  db/
    app.db                 # SQLite database (ALL parts, users, tags, lots)
  uploads/                 # user uploads (may be empty)
  public_media/            # part images / media
  Part-DB-server/          # git clone (build context) — not in this backup repo
  scripts/
    import_csv_inventory.ps1
    import_ssmg_pcbs.ps1
    codes.txt
  db-backup-*/             # dated SQLite backups
  RESTORE.md               # short human restore notes
  AGENT_INSTALL.md         # this file
```

**Do not** delete `db/app.db` unless intentionally resetting inventory.

---

## 12. Network / firewall (Windows Server)

- Local: `http://localhost:8080`
- LAN: allow inbound **TCP 8080** in Windows Firewall if other machines need access.
- Optional reverse proxy / Tailscale: `docker-compose.yaml` already sets `TRUSTED_PROXIES` for private ranges so HTTPS reverse proxies work with CSRF/login.

Example firewall rule (admin PowerShell):

```powershell
New-NetFirewallRule -DisplayName "Part-DB 8080" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```

---

## 13. Backup after changes

```powershell
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Path "db-backup-$stamp" | Out-Null
Copy-Item "db\app.db" "db-backup-$stamp\app.db"
# Optionally commit to the private GitHub repo (only if policy allows):
# git add db/app.db; git commit -m "db backup $stamp"; git push
```

Also back up `uploads/` and `public_media/` if users upload files.

---

## 14. Common failures and fixes

| Symptom | Fix |
|---------|-----|
| `no configuration file provided` | `cd` into folder with `docker-compose.yaml` |
| `path "...\Part-DB-server" not found` | Run **§4** clone; folder name must be exactly `Part-DB-server` |
| Build fails pulling base images | Check internet / Docker Hub; retry `docker compose up -d --build` |
| Port 8080 in use | Change host port in `docker-compose.yaml` or stop the conflicting service |
| HTTP 502 / empty for first 30s | Wait; check `docker logs partdb` |
| Permission warnings in console | Use `docker exec -u www-data partdb ...` |
| DigiKey import links only search pages | Reconnect DigiKey OAuth (**§9**) |
| API PATCH `415 Unsupported Media Type` | Use `Content-Type: application/merge-patch+json` for PATCH |
| API `401` | Create new API token in UI; set `$env:PARTDB_TOKEN` |
| Lost inventory | Restore from `db-backup-*/app.db` into `db/app.db`, then `docker compose restart` |

---

## 15. Ordered checklist for the agent (copy/paste execution order)

Execute **in order**. Stop on first failure; fix; continue.

1. [ ] Verify Git + Docker Desktop running (`docker info`).
2. [ ] Create install directory; `cd` into it.
3. [ ] `git clone https://github.com/abhinav937/PartDB-UW-madison.git .` (or into subfolder).
4. [ ] Confirm `docker-compose.yaml`, `secrets.env`, `db\app.db` exist; create `uploads` if missing.
5. [ ] `git clone https://github.com/abhinav937/Part-DB-server.git Part-DB-server`.
6. [ ] `git -C Part-DB-server checkout 148abe546be062a9a6a27fdca7f1c8fe98dbedf2`.
7. [ ] `docker compose up -d --build` (long first time).
8. [ ] `docker ps` → container `partdb` is Up; port `8080->80`.
9. [ ] HTTP GET `http://localhost:8080` → 200 + Part-DB.
10. [ ] Log in as `Abhinav` (reset password via console if needed).
11. [ ] In UI, confirm tags **Luke's Components** and **Abhinav's Components** filter parts.
12. [ ] (Optional) Reconnect DigiKey OAuth for info-provider features.
13. [ ] (Optional) Open firewall TCP 8080 for LAN.
14. [ ] Report to user: URL, login username, any passwords reset, and remaining issues.

---

## 16. Repo and pin references

| Item | Value |
|------|--------|
| Deployment repo | https://github.com/abhinav937/PartDB-UW-madison.git |
| App source fork | https://github.com/abhinav937/Part-DB-server.git |
| Upstream Part-DB | https://github.com/Part-DB/Part-DB-server.git |
| Pinned server commit | `148abe546be062a9a6a27fdca7f1c8fe98dbedf2` |
| Default URL | http://localhost:8080 |
| Compose service / container | `partdb` / image `partdb-custom:local` |
| Database | SQLite `./db/app.db` |

---

## 17. What not to do

- Do **not** force-push or make this repository public (`secrets.env` is committed).
- Do **not** change `BASE_CURRENCY` after DB creation (Part-DB treats it as permanent).
- Do **not** run `docker compose down -v` expecting data loss only of anonymous volumes — **named host binds** (`./db`, etc.) still keep data; wiping `db/app.db` is what destroys inventory.
- Do **not** commit `scripts/*.log` or local OAuth dumps.
- Do **not** skip pinning `Part-DB-server` commit unless the user explicitly wants a newer build.

---

## 18. Short human version

See also **`RESTORE.md`** for a minimal three-step restore. Prefer **this file** for automated agent handoff on Windows.
