#!/bin/bash
# 增强健壮性：-e(错误退出) -u(未定义变量退出) -o pipefail(管道失败传递)
set -euo pipefail
# 版本号
VERSION=1.0.0
# ==================== 可配置变量（建议在主脚本修改）====================
# 目标磁盘
TARGET_DISK="${TARGET_DISK:-/dev/nvme0n1p2}"
# 临时挂载点
MOUNT_POINT="${MOUNT_PARENT:-/run/snapshots}/d_$(date +%H%M%S)/"
# 快照存放根目录
SNAPSHOT_PARENT_SUBVOL=${SNAPSHOT_PARENT_SUBVOL:-'@snapshots'}
# 日志文件路径
SNAPSHOT_LOG_PATH="${SNAPSHOT_LOG_PATH:-/var/log/btrfs_snap}"
LOG_FILE="${SNAPSHOT_LOG_PATH}/delete.log"
# =======================================================================

# 日志输出函数
log() {
    local MSG="[$(date +%Y-%m-%d_%H:%M:%S)] [删除脚本] $1"
    # echo "$MSG"
    echo "$MSG" >> "$LOG_FILE"
}

# 收尾操作函数
cleanup() {
    log "==== 开始收尾操作 ===="
    # 卸载临时挂载点
    if mount | grep "$(realpath ${MOUNT_POINT})" >/dev/null 2>&1; then
        log "卸载临时挂载点 ${MOUNT_POINT}"
        umount "${MOUNT_POINT}" >/dev/null 2>&1 || log "警告：卸载临时挂载点失败，请手动清理"
    fi

    # 删除临时目录
    if rmdir "${MOUNT_POINT}" >/dev/null 2>&1; then
        log "删除临时目录 ${MOUNT_POINT}"
    else
        log "警告：临时目录 ${MOUNT_POINT} 非空，未删除"
    fi
}

# 错误退出函数
error_exit() {
    log "错误：$1，开始执行收尾操作..."
    cleanup
    log "==== 删除任务执行失败 ===="
    exit 1
}

# 取消操作函数
cancel() {
    log "捕获到 Ctrl+C，开始执行收尾操作..."
    cleanup
    echo -e "\n==== 删除任务执行取消 ===="
    log "==== 删除任务执行取消 ===="
    exit 0
}

# 绑定 SIGINT 信号（Ctrl+C）
trap cancel SIGINT

# 确保日志目录存在
if [ ! -d "${SNAPSHOT_LOG_PATH}" ]; then
    mkdir -p "${SNAPSHOT_LOG_PATH}"
    chmod 755 "${SNAPSHOT_LOG_PATH}"
    log "日志目录不存在，已创建：${SNAPSHOT_LOG_PATH}"
fi

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 必须以 root 权限运行此脚本（使用 sudo）"
    exit 1
fi

log "==== 开始执行Btrfs快照删除任务 ===="

# 1. 创建临时挂载目录
log "创建临时挂载目录 ${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}" || error_exit "创建临时挂载目录失败"

# 2. 挂载目标磁盘
log "挂载 ${TARGET_DISK} 到 ${MOUNT_POINT}"
mount -t btrfs "${TARGET_DISK}" "${MOUNT_POINT}" || error_exit "挂载磁盘 ${TARGET_DISK} 失败"

# 3. 标准化快照父目录
SNAPSHOT_PARENT_DIR=$(realpath "${MOUNT_POINT}/${SNAPSHOT_PARENT_SUBVOL}")
if [ ! -d "${SNAPSHOT_PARENT_DIR}" ]; then
    error_exit "快照根目录 ${SNAPSHOT_PARENT_DIR} 不存在！"
fi

# 4. 列出所有可用快照批次（按时间倒序）
log "获取可用快照列表"
SNAP_BATCHES=($(
    find "${SNAPSHOT_PARENT_DIR}" -maxdepth 1 -type d \
        -name "*_snap_*" \
        | sort -r
))

# 检查是否有快照
if [ ${#SNAP_BATCHES[@]} -eq 0 ]; then
    echo -e "==== 未找到任何可用快照 ===="
    error_exit "未找到任何可用快照！"
fi

# 5. 打印快照列表（带序号）
echo -e "\n==== 可用快照批次列表（按时间倒序） ===="
for i in "${!SNAP_BATCHES[@]}"; do
    # 提取快照名称（仅保留最后一级目录）
    BATCH_NAME=$(basename "${SNAP_BATCHES[$i]}")
    # 提取时间戳和类型
    SNAP_TYPE=$(echo "${BATCH_NAME}" | awk -F'_' '{print $1}')
    SNAP_TIME=$(echo "${BATCH_NAME}" | awk -F'_' '{print $3"_"$4}')
    echo "[$((i+1))] ${BATCH_NAME} (类型：${SNAP_TYPE}快照，时间：${SNAP_TIME//_/ })"
done

# 6. 选择要删除的快照批次
echo -e "\n请输入要删除的快照序号（1-${#SNAP_BATCHES[@]}）："
read -r SELECTED_INDEX
# 校验输入
if ! [[ "${SELECTED_INDEX}" =~ ^[0-9]+$ ]] || [ "${SELECTED_INDEX}" -lt 1 ] || [ "${SELECTED_INDEX}" -gt ${#SNAP_BATCHES[@]} ]; then
    error_exit "输入的序号无效！"
fi
# 转换为数组索引（从0开始）
SELECTED_INDEX=$((SELECTED_INDEX-1))
SELECTED_BATCH_DIR="${SNAP_BATCHES[${SELECTED_INDEX}]}"
SELECTED_BATCH_NAME=$(basename "${SELECTED_BATCH_DIR}")
log "选择删除的快照批次：${SELECTED_BATCH_NAME}"

echo -e "\n警告：即将删除快照批次 [${SELECTED_BATCH_NAME}]，此操作不可恢复！"
echo -n "请确认是否删除（输入 YES 确认）："
read -r CONFIRM
# 转换为大写后判断，不区分大小写
if [ "$(echo "${CONFIRM}" | tr '[:lower:]' '[:upper:]')" != "YES" ]; then
    cleanup
    echo -e "\n==== 删除任务执行取消 ===="
    log "==== 删除任务执行取消 ===="
    exit 0
fi

# 8. 执行删除操作（核心逻辑）
log "开始删除快照批次：${SELECTED_BATCH_NAME}"
# 先删除批次目录内的所有子卷快照（Btrfs子卷需用subvolume delete）
if [ -d "${SELECTED_BATCH_DIR}" ]; then
    # 遍历并删除所有子卷快照
    for SUBVOL_SNAP in "${SELECTED_BATCH_DIR}"/*/; do
        # 标准化路径，去掉末尾/
        SUBVOL_SNAP=$(realpath "${SUBVOL_SNAP}")
        # 验证是否为Btrfs子卷
        if btrfs subvolume show "${SUBVOL_SNAP}" >/dev/null 2>&1; then
            SUBVOL_NAME=$(basename "${SUBVOL_SNAP}")
            log "删除子卷快照：${SUBVOL_NAME}"
            btrfs subvolume delete "${SUBVOL_SNAP}" >/dev/null 2>&1 || log "警告：删除子卷 ${SUBVOL_NAME} 失败"
        fi
    done

    # 删除空的批次目录
    if rmdir "${SELECTED_BATCH_DIR}" >/dev/null 2>&1; then
        log "成功删除快照批次目录：${SELECTED_BATCH_NAME}"
        echo -e "\n 快照批次 [${SELECTED_BATCH_NAME}] 删除成功！"
    else
        log "警告：快照批次目录 ${SELECTED_BATCH_NAME} 非空，未完全删除！"
        echo -e "\n  快照批次 [${SELECTED_BATCH_NAME}] 部分删除（目录非空），请手动清理！"
    fi
else
    error_exit "快照批次目录 ${SELECTED_BATCH_NAME} 不存在！"
fi

# 9. 执行收尾操作
cleanup

log "==== 快照删除任务执行完成 ===="
log "成功删除快照批次：${SELECTED_BATCH_NAME}"

exit 0
