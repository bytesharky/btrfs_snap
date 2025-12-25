# Btrfs Snapshot Management Tool
btrfs_snap.sh is An automated Btrfs file system snapshot management tool implemented with Bash scripts. It supports manual/hourly/boot-time snapshot creation, interactive snapshot restoration, and enables automatic boot-time and hourly scheduled snapshots via systemd.

## Features
- 📸 **Multiple Snapshot Types**: Supports four snapshot types: manual, hourly, boot-time, and rollback backup
- 🧹 **Auto Cleanup**: Automatically retains a specified number of hourly/boot-time snapshots and cleans up outdated ones
- 🔄 **Safe Restoration**: Interactive snapshot restoration with automatic backup snapshots created before restoration
- 🕒 **Automated Deployment**: One-click installation of systemd services for auto-start on boot and hourly scheduled snapshots
- 📝 **Comprehensive Logging**: All operations are logged for easy troubleshooting
- 🔒 **Security Validation**: Strict permission, path, and subvolume validation to prevent misoperations

## Script Components
| Script File | Function Description |
|-------------|----------------------|
| `btrfs_snap.sh` | Main control script with unified configuration and permission validation, calls create/restore sub-scripts |
| `btrfs_snap_create.sh` | Core snapshot creation script, implements creation of different snapshot types and cleanup of old snapshots |
| `btrfs_snap_restore.sh` | Core snapshot restoration script, enables interactive selection of snapshot batches and subvolumes for restoration |
| `btrfs_snap_delete.sh` | Core snapshot deletion script, enables interactive selection of snapshot batches for deletion |
| `btrfs_snap_service.sh` | systemd service management script, one-click installation/uninstallation of boot-time/scheduled snapshot services |

## Environment Requirements
- **Operating System**: Linux system (with Btrfs and systemd support)
- **Permissions**: All operations require **root privileges** (using `sudo`)
- **Dependencies**: `btrfs-progs` (Btrfs toolset), `bash`, `systemd`
- **Disk**: Target disk must be formatted with Btrfs file system, and specified subvolumes must be created (`@`/`@var`/`@usr`/`@home`/`@data`)

### Dependency Installation
```bash
# Debian/Ubuntu-based systems
sudo apt update && sudo apt install -y btrfs-progs

# RHEL/CentOS-based systems
sudo yum install -y btrfs-progs

# Arch/Manjaro-based systems
sudo pacman -S --noconfirm btrfs-progs
```

## Quick Start

### 1. Download Scripts
Place all five scripts in the same directory, recommended path: `/usr/local/bin/btrfs-snap/`
```bash
# Create directory
sudo mkdir -p /usr/local/bin/btrfs-snap
# Place the five scripts in this directory
# Grant executable permissions
sudo chmod +x /usr/local/bin/btrfs-snap/*.sh
```

### 2. Configuration Modification (Important)
Edit the main script `btrfs_snap.sh` and modify the following core configurations (adjust according to your actual environment):
```bash
# Target disk (required, modify to your Btrfs partition path)
export TARGET_DISK="/dev/nvme0n1p2"
# Number of snapshots to retain (optional)
export KEEP_HOURLY_BATCHES=168  # Retain hourly snapshots for 7 days (24×7)
export KEEP_BOOT_BATCHES=7      # Retain 7 boot-time snapshots
# List of subvolumes to snapshot (adjust according to actual subvolume names)
export SRC_SUBVOLS=(
    "@"
    "@var"
    "@usr"
    "@home"
    "@data"
)
```

### 3. Basic Usage

#### Create Snapshots
```bash
# Enter script directory
cd /usr/local/bin/btrfs-snap

# Create manual snapshot
sudo ./btrfs_snap.sh --create

# Or use any value other than [restore, boot, hourly]
sudo ./btrfs_snap.sh --create manual

# Create hourly snapshot (manual trigger)
sudo ./btrfs_snap.sh --create hourly

# Create boot-time snapshot (manual trigger)
sudo ./btrfs_snap.sh --create boot

# Create rollback backup snapshot (manual trigger)
# You should NOT execute this manually
# It should be executed automatically by the snapshot restoration script
sudo ./btrfs_snap.sh --create restore
```

#### Restore Snapshots
```bash
# Enter script directory
cd /usr/local/bin/btrfs-snap

# Interactive snapshot restoration (lists all available snapshots for selection)
sudo ./btrfs_snap.sh --restore
```

#### Delete Snapshots
```bash
# Enter script directory
cd /usr/local/bin/btrfs-snap

# Interactive snapshot deletion
sudo ./btrfs_snap.sh --delete
```

#### View Help
```bash
sudo ./btrfs_snap.sh --help
```

### 4. Automated Deployment (Recommended)
Use `btrfs_snap.sh` for one-click installation of systemd services to achieve:
- Automatic creation of boot-type snapshots on system startup
- Automatic creation of hourly-type snapshots every hour

```bash
# Enter script directory
cd /usr/local/bin/btrfs-snap

# Install service
sudo ./btrfs_snap.sh --install

# View service status
sudo ./btrfs_snap.sh --status

# Uninstall service
sudo ./btrfs_snap.sh --uninstall
```

## Core Configuration Description
| Configuration Item | Default Value | Description |
|--------------------|---------------|-------------|
| `TARGET_DISK` | `/dev/nvme0n1p2` | Target Btrfs partition path |
| `MOUNT_PARENT_POINT` | `/run/snapshots` | Parent directory for temporary mount points |
| `SNAPSHOT_PARENT_SUBVOL` | `@snapshots` | Name of the subvolume for storing snapshots |
| `SNAPSHOT_LOG_PATH` | `/var/log/btrfs_snap` | Log file storage directory |
| `KEEP_HOURLY_BATCHES` | 168 | Number of hourly snapshots to retain (24×7) |
| `KEEP_BOOT_BATCHES` | 7 | Number of boot-time snapshots to retain |
| `SRC_SUBVOLS` | `@`/`@var`/`@usr`/`@home`/`@data` | List of subvolumes to create snapshots for |

## Log Viewing
```bash
# View main log
sudo tail -f /var/log/btrfs_snap/btrfs_snap.log

# View snapshot creation log
sudo tail -f /var/log/btrfs_snap/create.log

# View systemd service logs
sudo journalctl -u btrfs-snap-boot.service -f
sudo journalctl -u btrfs-snap-hourly.service -f
```

## Snapshot Directory Structure
Snapshots are stored in batches under the `@snapshots` subvolume of the Btrfs partition, with the following structure:
```bash
/@snapshots/
├── hourly_snap_20251224_100000/  # Hourly snapshot batch
│   ├── @                         # Root directory snapshot
│   ├── @var                      # Var directory snapshot
│   └── ...
├── boot_snap_20251224_090000/    # Boot-time snapshot batch
│   ├── @
│   ├── @var
│   └── ...
└── manual_snap_20251224_110000/  # Manual snapshot batch
    ├── @
    ├── @var
    └── ...
```

## Notes
1. **Permission Requirements**: All operations must be performed with root privileges (`sudo`)
2. **Data Security**: A `restore` type backup snapshot is automatically created before snapshot restoration to prevent restoration failures
3. **Subvolume Validation**: The script automatically validates whether subvolumes exist and are Btrfs subvolumes; non-existent subvolumes are skipped
4. **Cleanup Mechanism**: Only hourly/boot-time snapshots are automatically cleaned up; manual snapshots are not deleted automatically
5. **Post-Restoration Operation**: It is recommended to restart the system after snapshot restoration to ensure changes take effect
6. **Temporary Directory**: The script automatically creates temporary mount points and cleans them up after operations. If interrupted abnormally, you can unmount manually:
   ```bash
   sudo umount /run/snapshots/c_* || true
   sudo umount /run/snapshots/r_* || true
   sudo rmdir /run/snapshots/c_* /run/snapshots/r_* || true
   ```

## Frequently Asked Questions

### Q1: Script prompts "Not a Btrfs subvolume"
- Check if the subvolume names configured in `SRC_SUBVOLS` match the actual ones
- Verify subvolume existence: `sudo btrfs subvolume list /`

### Q2: Scheduled tasks do not execute
- Check timer status: `sudo systemctl list-timers btrfs-snap.timer`
- Check logs: `sudo journalctl -u btrfs-snap.timer -f`
- Ensure the target disk path is configured correctly

### Q3: System fails to boot after snapshot restoration
- Ensure the restored subvolumes are consistent with system mount configurations
- Boot via Live CD, remount the partition, and restore the latest backup snapshot

## License
This script is for learning and personal use only and has no official license. Please back up important data before use.

---

### Summary
1. This tool includes 5 core scripts that implement the full lifecycle of Btrfs snapshot creation, restoration, and automated deployment. The core is the `btrfs_snap.sh` main script, which uniformly calls the create/restore sub-scripts.
2. It supports three active snapshot types: manual, hourly, and boot-time. A backup snapshot is automatically created during restoration, and old data of hourly/boot-time snapshots can be cleaned up automatically.
3. Systemd services can be deployed with just one click to achieve automatic boot-time snapshots and hourly scheduled snapshots, reducing manual operation costs.
