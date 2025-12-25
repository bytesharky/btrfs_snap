#!/bin/bash
# 增强健壮性：-e(错误退出) -u(未定义变量退出) -o pipefail(管道失败传递)
set -euo pipefail
# 版本号
VERSION=1.0.1
# ==================== 可配置变量（建议在主脚本修改）====================
# 目标磁盘
TARGET_DISK="${TARGET_DISK:-/dev/nvme0n1p2}"
# 临时挂载点
MOUNT_POINT="${MOUNT_PARENT:-/run/snapshots}/c_$(date +%H%M%S)/"
# 快照存放根目录
SNAPSHOT_PARENT_SUBVOL=${SNAPSHOT_PARENT_SUBVOL:-'@snapshots'}
# 【小时快照】保留批次数量（24h×7天=168个）
KEEP_HOURLY_BATCHES=${KEEP_HOURLY_BATCHES:-168}
# 【启动快照】保留批次数量（建议保留7-30个）
KEEP_BOOT_BATCHES=${KEEP_BOOT_BATCHES:-7}
# 日志文件路径
SNAPSHOT_LOG_PATH="${SNAPSHOT_LOG_PATH:-/var/log/btrfs_snap}"
LOG_FILE="${SNAPSHOT_LOG_PATH}/create.log"
# 要快照的子卷列表
if [ -z "${SRC_SUBVOLS:-}" ]; then
    SRC_SUBVOLS=(
        "@"
        "@var"
        "@usr"
        "@home"
        "@data"
    )
fi
# =======================================================================

# 日志输出函数（同时输出到控制台和日志文件）
log() {
    local MSG="[$(date +%Y-%m-%d_%H:%M:%S)] [${MODE_NAME}] $1"
    echo "$MSG"
    echo "$MSG" >> "$LOG_FILE"
}


cleanup() {
    # 6. 收尾操作
    log "==== 开始收尾操作 ===="
    log "卸载临时挂载点 ${MOUNT_POINT}"
    umount "${MOUNT_POINT}" || {
        log "警告：卸载 ${MOUNT_POINT} 失败！请手动检查并卸载"
    }

    if mount | grep "$(realpath $MOUNT_POINT)" >/dev/null 2>&1 ; then
        log "卸载临时挂载点 ${MOUNT_POINT}"
        umount "${MOUNT_POINT}" >/dev/null 2>&1 || log "警告：卸载临时挂载点失败，请手动清理"
    fi

    # 删除空的临时挂载目录
    if rmdir "${MOUNT_POINT}" >/dev/null 2>&1; then
        log "成功删除临时目录 ${MOUNT_POINT}"
    else
        log "警告：临时目录 ${MOUNT_POINT} 非空，未删除（请手动清理）"
    fi
}

cancel() {
    log "捕获到 Ctrl+C，开始执行收尾操作..."
    cleanup
    log "==== 本次Btrfs${MODE_NAME}任务执行取消 ===="
    exit 0
}

# 绑定 SIGINT 信号到 cleanup 函数
trap cancel SIGINT

# 确保日志目录存在
if [ ! -d "${SNAPSHOT_LOG_PATH}" ]; then
    mkdir -p "${SNAPSHOT_LOG_PATH}"
    chmod 755 "${SNAPSHOT_LOG_PATH}"
    log "日志目录不存在，已创建：${SNAPSHOT_LOG_PATH}"
fi

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    log "错误: 必须以 root 权限运行此脚本（使用 sudo）"
    exit 1
fi

# 默认模式：手动快照
SNAP_MODE="${1:-manual}"

# 根据模式生成快照批次目录前缀
case "${SNAP_MODE}" in
    "restore")
        MODE_NAME="回滚快照"
        BATCH_PREFIX="restore_snap"
        # 回滚快照不清理旧快照
        KEEP_BATCHES=0
        ;;
    "hourly")
        MODE_NAME="小时快照"
        BATCH_PREFIX="hourly_snap"
        KEEP_BATCHES=${KEEP_HOURLY_BATCHES}
        ;;
    "boot")
        MODE_NAME="启动快照"
        BATCH_PREFIX="boot_snap"
        KEEP_BATCHES=${KEEP_BOOT_BATCHES}
        ;;
    "manual"|*)
        MODE_NAME="手动快照"
        BATCH_PREFIX="${SNAP_MODE}_snap"
        # 手动快照不清理旧快照
        KEEP_BATCHES=0
        ;;
esac

# 生成全局时间戳（所有子卷共用一个快照批次目录）
GLOBAL_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SNAPSHOT_BATCH_DIR="${BATCH_PREFIX}_${GLOBAL_TIMESTAMP}"

log "==== 开始执行Btrfs快照任务 ===="
log "本次快照批次目录：${SNAPSHOT_BATCH_DIR}"

# 1. 创建临时挂载目录
log "创建临时挂载目录 ${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}" || {
    log "错误：创建目录 ${MOUNT_POINT} 失败！"
    log "==== 本次快照任务执行失败 ===="
    exit 1
}

# 2. 挂载目标磁盘
log "挂载 ${TARGET_DISK} 到 ${MOUNT_POINT}"
mount -t btrfs "${TARGET_DISK}" "${MOUNT_POINT}" || {
    log "错误：挂载 ${TARGET_DISK} 到 ${MOUNT_POINT} 失败！"
    rmdir "${MOUNT_POINT}" >/dev/null 2>&1 || true
    log "==== 本次快照任务执行失败 ===="
    exit 1
}
log "成功挂载磁盘 ${TARGET_DISK}"

# 标准化快照父目录（@snapshots子卷路径）
SNAPSHOT_PARENT_DIR=$(realpath "${MOUNT_POINT}/${SNAPSHOT_PARENT_SUBVOL}")
# 本次快照批次的完整路径
SNAPSHOT_BATCH_FULL_PATH="${SNAPSHOT_PARENT_DIR}/${SNAPSHOT_BATCH_DIR}"
log "本次快照存放路径：${SNAPSHOT_BATCH_FULL_PATH}"

# 3. 创建本次快照批次目录（所有子卷快照的父目录）
log "创建快照批次目录 ${SNAPSHOT_BATCH_FULL_PATH}"
mkdir -p "${SNAPSHOT_BATCH_FULL_PATH}" || {
    log "错误：创建快照批次目录 ${SNAPSHOT_BATCH_FULL_PATH} 失败！"
    umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
    rmdir "${MOUNT_POINT}" >/dev/null 2>&1 || true
    log "==== 本次快照任务执行失败 ===="
    exit 1
}

# 4. 遍历子卷创建快照（放入同一时间戳目录）
for SRC_SUBVOL in "${SRC_SUBVOLS[@]}"; do
    # 源子卷完整路径
    SRC_FULL_PATH=$(realpath "${MOUNT_POINT}/${SRC_SUBVOL}")
    log "==== 处理子卷：${SRC_SUBVOL} ===="

    # 检查源子卷是否存在且是Btrfs子卷
    if [ ! -d "${SRC_FULL_PATH}" ]; then
        log "警告：源子卷 ${SRC_FULL_PATH} 不存在，跳过！"
        continue
    fi
    if ! btrfs subvolume show "${SRC_FULL_PATH}" >/dev/null 2>&1; then
        log "警告：${SRC_FULL_PATH} 不是Btrfs子卷，跳过！"
        continue
    fi

    # 单个子卷的快照路径（如 @snapshots/hourly_snap_20251223_164043/@var）
    SUBVOL_SNAP_PATH="${SNAPSHOT_BATCH_FULL_PATH}/${SRC_SUBVOL}"

    # 创建只读快照
    log "创建只读快照：${SRC_FULL_PATH} -> ${SUBVOL_SNAP_PATH}"
    if btrfs subvolume snapshot -r "${SRC_FULL_PATH}" "${SUBVOL_SNAP_PATH}" > /dev/null 2>&1; then
        log "成功创建 ${SRC_SUBVOL} 快照"
    else
        log "错误：为 ${SRC_SUBVOL} 创建快照失败！"
        continue
    fi
done

# 5. 清理旧快照批次（仅非手动模式执行）
if [ "${KEEP_BATCHES}" -gt 0 ]; then
    log "==== 开始清理旧快照批次（保留最新 ${KEEP_BATCHES} 个） ===="
    # 筛选当前模式下的所有快照批次目录（按前缀匹配，时间倒序）
    OLD_SNAP_BATCHES=($(
        find "${SNAPSHOT_PARENT_DIR}" -maxdepth 1 -type d \
            -name "${BATCH_PREFIX}_*" \
            | sort -r
    ))

    # 检查批次数量是否超出限制
    if [ ${#OLD_SNAP_BATCHES[@]} -gt "$KEEP_BATCHES" ]; then
        DELETE_COUNT=$(( ${#OLD_SNAP_BATCHES[@]} - KEEP_BATCHES ))
        log "当前${MODE_NAME}批次数量(${#OLD_SNAP_BATCHES[@]})超出上限(${KEEP_BATCHES})，需删除${DELETE_COUNT}个旧批次"

        # 遍历超出的批次目录，删除其中所有子卷快照，再删除目录
        for ((i=KEEP_BATCHES; i<${#OLD_SNAP_BATCHES[@]}; i++)); do
            OLD_BATCH_DIR="${OLD_SNAP_BATCHES[$i]}"
            log "清理旧快照批次：${OLD_BATCH_DIR}"

            # 先删除批次目录内的所有子卷快照（Btrfs子卷需用subvolume delete）
            if [ -d "${OLD_BATCH_DIR}" ]; then
                find "${OLD_BATCH_DIR}" -mindepth 1 -maxdepth 1 -type d \
                    -exec btrfs subvolume delete {} >/dev/null 2>&1 \;
            fi

            # 删除空的批次目录
            if rmdir "${OLD_BATCH_DIR}" >/dev/null 2>&1; then
                log "成功删除旧批次目录：${OLD_BATCH_DIR}"
            else
                log "警告：旧批次目录 ${OLD_BATCH_DIR} 非空，未完全删除！"
            fi
        done
    else
        log "当前${MODE_NAME}批次数量(${#OLD_SNAP_BATCHES[@]})未超上限(${KEEP_BATCHES})，无需清理"
    fi
else
    log "==== 手动快照模式，跳过旧快照清理 ===="
fi

# 执行收尾
cleanup

log "==== 本次Btrfs${MODE_NAME}任务执行完成 ===="
exit 0
