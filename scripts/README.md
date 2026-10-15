# WordPress Deployment Scripts and Backup Utilities Guide

This directory contains deployment and maintenance utilities for the Dockerized WordPress stack, modeled after the enterprise-grade backup and snapshot architecture.

---

## Table of Contents

1. [Snapshot Utility (Full Backup)](#snapshot-utility)
2. [Backup Data Utility (Data & DB Zip)](#backup-data-utility)
3. [Restore Snapshot](#restore-snapshot)
4. [Restore Backup Data](#restore-backup-data)
5. [List Snapshots](#list-snapshots)
6. [Download Snapshot](#download-snapshot)
7. [Upload Snapshot](#upload-snapshot)
8. [Upload Temporary Snapshots](#upload-temporary-snapshots)
9. [Cleanup Snapshots (Retention)](#cleanup-snapshots)
10. [Generate Snapshot SSH Key](#generate-snapshot-ssh-key)
11. [Installation & Automated Cron](#installation--automated-cron)

---

## Snapshot Utility

Creates a full, production-grade WordPress snapshot containing:
- **MySQL Database**: Complete logical dump (`dump.sql`) using `mysqldump` executed securely with Docker secrets (`/run/secrets/db_password`).
- **WordPress Data**: Persistent directory `data/wordpress` containing WordPress core, `wp-config.php`, `wp-content/uploads`, themes, and plugins.
- **Configurations**: `.env`, `.secrets/`, `docker-compose.yml`, `php-config/`, `nginx_sites_available_configurations/`, `scripts/`, and any configured `SNAPSHOT_CUSTOM_DIRS`.
- **Metadata**: `manifest.json` (WordPress version, DB name, image tag, creation timestamp) and git commit hashes (`git_hashes.txt`).
- **Archive Format**: Compressed using high-performance Zstandard (`zstd`), saved as `snapshot-$SERVICE_NAME.tar.zst`.

### Storage Options
- **Local Archive**: Saved to `~/.wordpress-snapshots/$SERVICE_NAME/archives/` and symlinked to `~/snapshot-$SERVICE_NAME.tar.zst`.
- **Google Cloud Storage**: Set `GCS_BUCKET_NAME` in `.env` to automatically stream backups to `gs://$GCS_BUCKET_NAME/`.
- **Google Drive**: Set `GDRIVE_SERVICE_ACCOUNT_KEY` (or `GDRIVE_ACCESS_TOKEN`) and `GDRIVE_FOLDER_ID` for chunked, resumable cloud upload with automatic lifecycle retention (`GDRIVE_MAX_BACKUPS`).
- **Secondary VPS (Remote Offload)**: Set `SNAPSHOT_REMOTE_HOST` and `SNAPSHOT_REMOTE_USER` to stream the database dump and rsync files to a secondary VPS, where compression and cloud upload take place without consuming primary VPS CPU/memory.

### Usage
```bash
# Run manual snapshot locally
./scripts/snapshot-docker-wordpress.sh

# Or via system-wide symlink
sudo /usr/local/sbin/snapshot-docker-wordpress
```

---

## Backup Data Utility

Creates a focused zip bundle (`backupdata-$SERVICE_NAME.zip`) containing:
- `dump.sql` (MySQL database dump)
- `manifest.json` (WordPress and database metadata)
- `wordpress/` directory (`data/wordpress`)

```bash
# Run backupdata utility
./scripts/backupdata-docker-wordpress.sh

# Or via system-wide symlink
sudo /usr/local/sbin/backupdata-docker-wordpress
```

The output file is saved to `~/backupdata-$SERVICE_NAME.zip` and optionally transferred to the Secondary VPS if configured in `.env`.

---

## Restore Snapshot

Restores the WordPress deployment from a `.tar.zst` snapshot archive.

```bash
# Full restore (stops stack, restores configs, env, data/wordpress, starts db, restores MySQL dump, starts stack)
./scripts/restore-snapshot.sh

# Fast data-only restore (restores database + data/wordpress only, skips config/env overwrite and container restarts)
./scripts/restore-snapshot.sh --data-only

# Fast data-only restore to a renamed/custom target database without confirmation prompt
./scripts/restore-snapshot.sh --data-only -n my_test_db -y

# Specify a custom snapshot file path
./scripts/restore-snapshot.sh --file /path/to/snapshot-archive.tar.zst
```

---

## Restore Backup Data

Restores the database and WordPress data from a `backupdata-$SERVICE_NAME.zip` file.

```bash
# Restore default ~/backupdata-docker-wordpress.zip
./scripts/restore_backupdata-docker-wordpress.sh

# Restore with target database override and skip prompt
./scripts/restore_backupdata-docker-wordpress.sh ~/my-backup.zip -n custom_wp_db -y
```

---

## List Snapshots

Lists snapshot files stored in Google Drive or local archives with size and creation dates.

```bash
# List snapshots on Google Drive for current service
./scripts/list-snapshot.sh

# List snapshots across all services
./scripts/list-snapshot.sh --all

# List local snapshots in ~/.wordpress-snapshots/
./scripts/list-snapshot.sh --local

# Output in JSON format
./scripts/list-snapshot.sh --json
```

---

## Download Snapshot

Downloads a snapshot archive directly from Google Drive by File ID, sharing URL, filename, or `latest`.

```bash
# Fetch the latest snapshot for this project
./scripts/download-snapshot.sh latest

# Download using Google Drive File ID
./scripts/download-snapshot.sh 1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OIvE2up0Y

# Download using Google Drive sharing URL
./scripts/download-snapshot.sh "https://drive.google.com/file/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OIvE2up0Y/view"

# Interactive selection picker
./scripts/download-snapshot.sh
```

By default, the downloaded file is saved to `~/<filename>` and symlinked to `~/snapshot-$SERVICE_NAME.tar.zst` for immediate restore using `./scripts/restore-snapshot.sh`.

---

## Upload Snapshot

Uploads a local snapshot archive to Google Drive using Google Service Account credentials or OAuth2 token configured in `.env`.

```bash
# Upload default snapshot (~/snapshot-docker-wordpress.tar.zst)
./scripts/upload-snapshot.sh

# Upload specific snapshot archive
./scripts/upload-snapshot.sh /path/to/snapshot-archive.tar.zst

# Upload with custom Google Drive folder ID override
./scripts/upload-snapshot.sh --folder-id "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OIvE2up0Y"
```

---

## Upload Temporary Snapshots

Uploads all pending/temporary local snapshots (stored in `~/.wordpress-snapshots/$SERVICE_NAME/archives` or `~/.wordpress-tmp`) to Google Drive or Google Cloud Storage, cleaning up local files upon verified upload.

```bash
# Upload all pending local snapshots
./scripts/upload-temp-snapshots.sh

# Dry-run preview
./scripts/upload-temp-snapshots.sh --dry-run

# Keep local archives after upload
./scripts/upload-temp-snapshots.sh --keep-local
```

---

## Cleanup Snapshots (Retention)

Inspects and deletes older snapshots on Google Drive based on the retention policy (`GDRIVE_MAX_BACKUPS`, default 7).

```bash
# List snapshots and their retention status (KEEP / DELETE)
./scripts/cleanup-snapshot.sh -l

# Dry-run deletion preview
./scripts/cleanup-snapshot.sh --dry-run

# Retain only the 5 newest snapshots and force deletion
./scripts/cleanup-snapshot.sh --keep 5 --force
```

---

## Generate Snapshot SSH Key

Generates a dedicated ed25519 SSH key pair (`~/.ssh/snapshot-$THIS_VPS_HOSTNAME-$TARGET_VPS_HOSTNAME`) for passwordless remote backups to a Secondary VPS, updates `SNAPSHOT_REMOTE_KEY` in `.env`, and outputs the public key with instructions for authorization on the remote VPS.

```bash
# Interactive or using .env SNAPSHOT_REMOTE_HOST
./scripts/generate-snapshot-ssh-key.sh

# Specify target VPS host directly
./scripts/generate-snapshot-ssh-key.sh --target-host backup-vps.example.com --target-user wpbackup
```

---

## Installation & Automated Cron

To install all snapshot and backup utilities, symlinks, and cron jobs:

1. Configure `.env`:
   ```bash
   ENABLE_SNAPSHOT=Y
   SNAPSHOT_TIME=2           # Run daily at 02:00 (or interval like */4)
   GDRIVE_MAX_BACKUPS=7      # Retain latest 7 snapshots in Google Drive
   ```

2. Run installer scripts:
   ```bash
   sudo ./scripts/installer/install-snapshot.sh
   sudo ./scripts/installer/install-backupdata.sh
   sudo ./scripts/installer/install-restore_backupdata.sh
   sudo ./scripts/installer/install_sudoers.sh
   ```

3. To uninstall:
   ```bash
   sudo ./scripts/installer/uninstall-snapshot.sh
   ```
