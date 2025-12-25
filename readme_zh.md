# Btrfs 快照管理工具

btrfs_snap.sh 是一个基于 Bash 脚本实现的 Btrfs 文件系统快照自动化管理工具，支持手动/小时/开机快照创建、交互式快照恢复，并可通过 systemd 实现开机自动快照和每小时定时快照。

## 功能特性
- 📸 **多类型快照**：支持手动、小时、开机、回滚备份四种快照类型
- 🧹 **自动清理**：小时/开机快照自动保留指定数量，超出自动清理
- 🔄 **安全恢复**：交互式恢复快照，恢复前自动创建备份快照
- 🕒 **自动化部署**：一键安装 systemd 服务，实现开机自启和每小时定时快照
- 📝 **完善日志**：所有操作记录日志，便于问题排查
- 🔒 **安全校验**：严格的权限、路径、子卷校验，避免误操作

## 脚本组成
| 脚本文件 | 功能描述 |
|----------|----------|
| `btrfs_snap.sh` | 主控制脚本，统一配置、权限校验，调用创建/恢复子脚本 |
| `btrfs_snap_create.sh` | 快照创建核心脚本，实现不同类型快照的创建和旧快照清理 |
| `btrfs_snap_restore.sh` | 快照恢复核心脚本，交互式选择快照批次和子卷进行恢复 |
| `btrfs_snap_delete.sh` | 快照删除核心脚本，交互式选择快照批次进行删除 |
| `btrfs_snap_service.sh` | systemd 服务管理脚本，一键安装/卸载开机/定时快照服务 |

## 环境要求
- 操作系统：Linux 系统（需支持 Btrfs 和 systemd）
- 权限：所有操作需 **root 权限**（使用 `sudo`）
- 依赖：`btrfs-progs`（Btrfs 工具集）、`bash`、`systemd`
- 磁盘：目标磁盘需为 Btrfs 文件系统，且已创建指定子卷（`@`/`@var`/`@usr`/`@home`/`@data`）

### 依赖安装
```bash
# Debian/Ubuntu 系
sudo apt update && sudo apt install -y btrfs-progs

# RHEL/CentOS 系
sudo yum install -y btrfs-progs

# Arch/Manjaro 系
sudo pacman -S --noconfirm btrfs-progs
```

## 快速开始

### 1. 下载脚本
将五个脚本放在同一目录下，建议路径：`/usr/local/bin/btrfs-snap/`
```bash
# 创建目录
sudo mkdir -p /usr/local/bin/btrfs-snap
# 将五个脚本放入该目录
# 赋予执行权限
sudo chmod +x /usr/local/bin/btrfs-snap/*.sh
```

### 2. 配置修改（重要）
编辑主脚本 `btrfs_snap.sh`，修改以下核心配置（根据实际环境调整）：
```bash
# 目标磁盘（必填，修改为你的 Btrfs 分区路径）
export TARGET_DISK="/dev/nvme0n1p2"
# 快照保留数量（可选）
export KEEP_HOURLY_BATCHES=168  # 小时快照保留7天（24×7）
export KEEP_BOOT_BATCHES=7      # 开机快照保留7个
# 需快照的子卷列表（根据实际子卷名调整）
export SRC_SUBVOLS=(
    "@"
    "@var"
    "@usr"
    "@home"
    "@data"
)
```

### 3. 基本使用

#### 创建快照
```bash
# 进入脚本目录
cd /usr/local/bin/btrfs-snap

# 创建手动快照
sudo ./btrfs_snap.sh --create

# 或者非[restore，boot，hourly]的任意值
sudo ./btrfs_snap.sh --create manual

# 创建小时快照（手动触发）
sudo ./btrfs_snap.sh --create hourly

# 创建开机快照（手动触发）
sudo ./btrfs_snap.sh --create boot

# 创建回滚备份快照（手动触发）
# 你不应该手动执行它
# 它应该由恢复快照脚自动执行
sudo ./btrfs_snap.sh --create restore
```

#### 恢复快照
```bash
# 进入脚本目录
cd /usr/local/bin/btrfs-snap

# 交互式恢复快照（会列出所有可用快照供选择）
sudo ./btrfs_snap.sh --restore
```

#### 删除快照
```bash
# 进入脚本目录
cd /usr/local/bin/btrfs-snap

# 交互式删除快照
sudo ./btrfs_snap.sh --delete
```

#### 查看帮助
```bash
sudo ./btrfs_snap.sh --help
```

### 4. 自动化部署（推荐）
通过 `btrfs_snap.sh` 一键安装 systemd 服务，实现：
- 开机自动创建 boot 类型快照
- 每小时自动创建 hourly 类型快照

```bash
# 进入脚本目录
cd /usr/local/bin/btrfs-snap

# 安装服务
sudo ./btrfs_snap.sh --install

# 查看服务状态
sudo ./btrfs_snap.sh --status

# 卸载服务
sudo ./btrfs_snap.sh --uninstall
```

## 核心配置说明
| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `TARGET_DISK` | `/dev/nvme0n1p2` | 目标 Btrfs 分区路径 |
| `MOUNT_PARENT_POINT` | `/run/snapshots` | 临时挂载点父目录 |
| `SNAPSHOT_PARENT_SUBVOL` | `@snapshots` | 快照存放的子卷名称 |
| `SNAPSHOT_LOG_PATH` | `/var/log/btrfs_snap` | 日志文件存放目录 |
| `KEEP_HOURLY_BATCHES` | 168 | 小时快照保留数量（24×7） |
| `KEEP_BOOT_BATCHES` | 7 | 开机快照保留数量 |
| `SRC_SUBVOLS` | `@`/`@var`/`@usr`/`@home`/`@data` | 需要创建快照的子卷列表 |

## 日志查看
```bash
# 查看主日志
sudo tail -f /var/log/btrfs_snap/btrfs_snap.log

# 查看创建快照日志
sudo tail -f /var/log/btrfs_snap/create.log

# 查看 systemd 服务日志
sudo journalctl -u btrfs-snap-boot.service -f
sudo journalctl -u btrfs-snap-hourly.service -f
```

## 快照目录结构
快照会按批次存放在 Btrfs 分区的 `@snapshots` 子卷下，结构如下：
```bash
/@snapshots/
├── hourly_snap_20251224_100000/  # 小时快照批次
│   ├── @                         # 根目录快照
│   ├── @var                      # var 目录快照
│   └── ...
├── boot_snap_20251224_090000/    # 开机快照批次
│   ├── @
│   ├── @var
│   └── ...
└── manual_snap_20251224_110000/  # 手动快照批次
    ├── @
    ├── @var
    └── ...
```

## 注意事项
1. **权限要求**：所有操作必须使用 root 权限（`sudo`）
2. **数据安全**：恢复快照前会自动创建 `restore` 类型备份快照，防止恢复出错
3. **子卷校验**：脚本会自动校验子卷是否存在且为 Btrfs 子卷，不存在则跳过
4. **清理机制**：仅小时/开机快照会自动清理，手动快照不会自动删除
5. **恢复后操作**：快照恢复完成后，建议重启系统以确保生效
6. **临时目录**：脚本会自动创建临时挂载点，操作完成后自动清理，若异常中断可手动卸载：
   ```bash
   sudo umount /run/snapshots/c_* || true
   sudo umount /run/snapshots/r_* || true
   sudo rmdir /run/snapshots/c_* /run/snapshots/r_* || true
   ```

## 常见问题

### Q1: 执行脚本提示 "不是 Btrfs 子卷"
- 检查 `SRC_SUBVOLS` 配置的子卷名称是否与实际一致
- 验证子卷是否存在：`sudo btrfs subvolume list /`

### Q2: 定时任务不执行
- 检查 timer 状态：`sudo systemctl list-timers btrfs-snap.timer`
- 检查日志：`sudo journalctl -u btrfs-snap.timer -f`
- 确保目标磁盘路径配置正确

### Q3: 恢复快照后系统无法启动
- 确保恢复的子卷与系统挂载配置一致
- 可通过 Live CD 启动，重新挂载并恢复最新的备份快照

## 许可证
本脚本仅供学习和自用，无官方许可证，使用前请备份重要数据。

---

### 总结
1. 该工具包含5个核心脚本，实现了Btrfs快照的创建、恢复、自动化部署全流程，核心是`btrfs_snap.sh`主脚本，统一调用创建/恢复子脚本。
2. 支持手动/小时/开机三种主动快照类型，恢复时会自动创建备份快照，且小时/开机快照可自动清理旧数据。
3. 可通过一键部署systemd服务，实现开机自动快照和每小时定时快照，降低手动操作成本。
