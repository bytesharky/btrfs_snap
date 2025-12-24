#!/bin/bash
# 增强健壮性：-e(错误退出) -u(未定义变量退出) -o pipefail(管道失败传递)
set -euo pipefail
# 版本号
VERSION=1.0.0
# ==================== 可配置变量（建议在主脚本修改）====================
# 目标磁盘
TARGET_DISK="${TARGET_DISK:-/dev/nvme0n1p2}"
# 临时挂载点
MOUNT_POINT="${MOUNT_PARENT:-/run/snapshots}/r_$(date +%H%M%S)/"
# 快照存放根目录
SNAPSHOT_PARENT_SUBVOL=${SNAPSHOT_PARENT_SUBVOL:-'@snapshots'}
# 创建脚本路径（用于恢复前创建手动快照）
CREATE_SNAP_SCRIPT="${CREATE_SNAP_SCRIPT:-./btrfs_snap_create.sh}"
# 日志文件路径
SNAPSHOT_LOG_PATH="${SNAPSHOT_LOG_PATH:-/var/log/btrfs_snap}"
LOG_FILE="${SNAPSHOT_LOG_PATH}/create.log"
# =======================================================================

# 日志输出函数
log() {
    local MSG="[$(date +%Y-%m-%d_%H:%M:%S)] [恢复脚本] $1"
    # echo "$MSG"
    echo "$MSG" >> "$LOG_FILE"
}

cleanup() {
    # 收尾操作
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
    log "==== 恢复任务执行失败 ===="
    exit 1
}

cancel() {
    log "捕获到 Ctrl+C，开始执行收尾操作..."
    cleanup
    echo -e "\n==== 恢复任务执行取消 ===="
    log "==== 恢复任务执行取消 ===="
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
    echo "错误: 必须以 root 权限运行此脚本（使用 sudo）"
    exit 1
fi

# 检查创建脚本是否存在且可执行
if [ ! -f "${CREATE_SNAP_SCRIPT}" ] || [ ! -x "${CREATE_SNAP_SCRIPT}" ]; then
    error_exit "创建快照脚本 ${CREATE_SNAP_SCRIPT} 不存在或不可执行！请检查路径是否正确"
fi

log "==== 开始执行Btrfs快照恢复任务 ===="

# 创建临时挂载目录
log "创建临时挂载目录 ${MOUNT_POINT}"
mkdir -p "${MOUNT_POINT}" || error_exit "创建临时挂载目录失败"

# 挂载目标磁盘
log "挂载 ${TARGET_DISK} 到 ${MOUNT_POINT}"
mount -t btrfs "${TARGET_DISK}" "${MOUNT_POINT}" || error_exit "挂载磁盘 ${TARGET_DISK} 失败"

# 标准化快照父目录
SNAPSHOT_PARENT_DIR=$(realpath "${MOUNT_POINT}/${SNAPSHOT_PARENT_SUBVOL}")
if [ ! -d "${SNAPSHOT_PARENT_DIR}" ]; then
    error_exit "快照根目录 ${SNAPSHOT_PARENT_DIR} 不存在！"
fi

# 列出所有可用快照批次（按时间倒序）
log "获取可用快照列表"
# 筛选所有快照批次目录（manual/hourly/boot），按时间倒序
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

# 打印快照列表（带序号）
echo -e "\n==== 可用快照批次列表（按时间倒序） ===="
for i in "${!SNAP_BATCHES[@]}"; do
    # 提取快照名称（仅保留最后一级目录）
    BATCH_NAME=$(basename "${SNAP_BATCHES[$i]}")
    # 提取时间戳和类型
    SNAP_TYPE=$(echo "${BATCH_NAME}" | awk -F'_' '{print $1}')
    SNAP_TIME=$(echo "${BATCH_NAME}" | awk -F'_' '{print $3"_"$4}')
    echo "[$((i+1))] ${BATCH_NAME} (类型：${SNAP_TYPE}快照，时间：${SNAP_TIME//_/ })"
done

# 选择要恢复的快照批次
echo -e "\n请输入要恢复的快照序号（1-${#SNAP_BATCHES[@]}）："
read -r SELECTED_INDEX
# 校验输入
if ! [[ "${SELECTED_INDEX}" =~ ^[0-9]+$ ]] || [ "${SELECTED_INDEX}" -lt 1 ] || [ "${SELECTED_INDEX}" -gt ${#SNAP_BATCHES[@]} ]; then
    error_exit "输入的序号无效！"
fi
# 转换为数组索引（从0开始）
SELECTED_INDEX=$((SELECTED_INDEX-1))
SELECTED_BATCH_DIR="${SNAP_BATCHES[${SELECTED_INDEX}]}"
SELECTED_BATCH_NAME=$(basename "${SELECTED_BATCH_DIR}")
log "选择恢复的快照批次：${SELECTED_BATCH_NAME}"

# 筛选子卷快照
log "获取 ${SELECTED_BATCH_NAME} 下的子卷快照列表"
# 修复逻辑：先列出目录下所有子目录，再验证是否为Btrfs子卷（兼容所有Btrfs版本）
SUBVOL_SNAPS=()
# 遍历快照批次目录下的所有子目录
for DIR in "${SELECTED_BATCH_DIR}"/*/; do
    # 标准化路径，去掉末尾/
    DIR=$(realpath "${DIR}")
    # 验证是否为Btrfs子卷
    if btrfs subvolume show "${DIR}" >/dev/null 2>&1; then
        SUBVOL_SNAPS+=("${DIR}")
    fi
done

# 检查是否有可用子卷
if [ ${#SUBVOL_SNAPS[@]} -eq 0 ]; then
    error_exit "所选快照批次 ${SELECTED_BATCH_NAME} 下无可用子卷快照！"
fi

# 打印子卷列表
echo -e "\n==== ${SELECTED_BATCH_NAME} 下的子卷快照列表 ===="
for i in "${!SUBVOL_SNAPS[@]}"; do
    SUBVOL_NAME=$(basename "${SUBVOL_SNAPS[$i]}")
    echo "[$((i+1))] ${SUBVOL_NAME}"
done
# =========================================================================

# 选择恢复范围（全部/部分）
echo -e "\n请选择恢复范围："
echo "1) 恢复所有子卷"
echo "2) 恢复指定子卷"
read -r RESTORE_SCOPE
case "${RESTORE_SCOPE}" in
    1)
        RESTORE_SUBVOLS=("${SUBVOL_SNAPS[@]}")
        log "选择恢复所有子卷"
        ;;
    2)
        echo -e "\n请输入要恢复的子卷序号（多个序号用空格分隔，如：1 3 5）："
        read -r SUBVOL_INDEXES
        # 解析输入的序号，转换为子卷路径
        RESTORE_SUBVOLS=()
        for idx in ${SUBVOL_INDEXES}; do
            if ! [[ "${idx}" =~ ^[0-9]+$ ]] || [ "${idx}" -lt 1 ] || [ "${idx}" -gt ${#SUBVOL_SNAPS[@]} ]; then
                error_exit "子卷序号 ${idx} 无效！"
            fi
            RESTORE_SUBVOLS+=("${SUBVOL_SNAPS[$((idx-1))]}")
        done
        log "选择恢复指定子卷：${RESTORE_SUBVOLS[*]}"
        ;;
    *)
        error_exit "恢复范围选择无效！"
        ;;
esac

# 恢复前创建手动快照（防止二次伤害）
log "恢复前创建回滚备份快照（备份当前状态）"
if ! bash "${CREATE_SNAP_SCRIPT}" "restore" >/dev/null 2>&1; then
    error_exit "创建回滚备份快照失败！终止恢复操作"
fi
log "回滚备份快照创建成功"

# 执行恢复操作（核心）
log "开始恢复快照 ${SELECTED_BATCH_NAME}"
for SUBVOL_SNAP in "${RESTORE_SUBVOLS[@]}"; do
    SUBVOL_NAME=$(basename "${SUBVOL_SNAP}")
    # 目标子卷路径（顶层子卷）
    TARGET_SUBVOL_PATH=$(realpath "${MOUNT_POINT}/${SUBVOL_NAME}")

    log "正在恢复子卷：${SUBVOL_NAME}"

    # 1. 先卸载目标子卷（如果已挂载）
    if mount | grep "$(realpath ${TARGET_SUBVOL_PATH})" >/dev/null 2>&1 ; then
        log "卸载已挂载的 ${SUBVOL_NAME} 子卷"
        umount "${TARGET_SUBVOL_PATH}" >/dev/null 2>&1 || true
    fi

    # 2. 删除现有子卷（Btrfs恢复需先删除原卷）
    if btrfs subvolume show "${TARGET_SUBVOL_PATH}" >/dev/null 2>&1; then
        log "删除现有 ${SUBVOL_NAME} 子卷"
        btrfs subvolume delete "${TARGET_SUBVOL_PATH}" >/dev/null 2>&1 || error_exit "删除 ${SUBVOL_NAME} 子卷失败"
    fi

    # 3. 从快照恢复子卷（复制快照为可读写子卷）
    log "从快照 ${SUBVOL_SNAP} 恢复 ${SUBVOL_NAME}"
    btrfs subvolume snapshot "${SUBVOL_SNAP}" "${TARGET_SUBVOL_PATH}" >/dev/null 2>&1 || error_exit "恢复 ${SUBVOL_NAME} 子卷失败"

    log "子卷 ${SUBVOL_NAME} 恢复成功"
done

# 执行收尾
cleanup

log "==== 快照恢复任务执行完成 ===="
log "快照恢复成功！"
log "  恢复的快照批次：${SELECTED_BATCH_NAME}"
log "  恢复的子卷：${RESTORE_SUBVOLS[*]}"
log "  建议：重启系统以确保恢复生效，或手动重新挂载相关子卷"

exit 0
