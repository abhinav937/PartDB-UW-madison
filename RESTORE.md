# Restoring this Part-DB deployment

This repo is a full backup of the Part-DB deployment at `C:\PartDB`.

> ⚠️ `secrets.env` is committed here (private repo) so the deployment can be
> restored as-is. Treat this repo as sensitive.

> **AI agents / full Windows server handoff:** use **[AGENT_INSTALL.md](./AGENT_INSTALL.md)**
> (prerequisites, clone pins, Docker, DigiKey, tags, verification checklist).

## 1. Clone the backup

```bash
git clone https://github.com/abhinav937/PartDB-UW-madison.git PartDB
cd PartDB
```

## 2. Restore the Part-DB server source (excluded from this backup)

The `Part-DB-server/` folder is intentionally **not** stored here; it lives in
its own repo. Bring it back with:

```bash
git clone https://github.com/abhinav937/Part-DB-server.git Part-DB-server
cd Part-DB-server
git remote add upstream https://github.com/Part-DB/Part-DB-server.git
# Backup was taken at this commit:
git checkout 148abe546be062a9a6a27fdca7f1c8fe98dbedf2
cd ..
```

## 3. Bring the stack up

```bash
docker compose up -d
```

The included `db/`, `uploads/`, and `public_media/` folders carry the database
and user media, so the instance comes back with its data intact.
