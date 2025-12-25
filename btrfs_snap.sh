#!/bin/bash
# 增强健壮性：-e(错误退出) -u(未定义变量退出) -o pipefail(管道失败传递)
set -euo pipefail
# 版本号
VERSION=1.0.1
# 获取脚本自身的绝对路径（处理软链接）
SCRIPT_PATH=$(readlink -f "$0")
# 从绝对路径中提取目录部分
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# 公共配置
# =========================
# 目标磁盘
export TARGET_DISK=${TARGET_DISK:-"/dev/nvme0n1p2"}
# 挂载点父节点
export MOUNT_PARENT_POINT=${MOUNT_PARENT_POINT:-"/run/snapshots"}
# 快照存放根目录
export SNAPSHOT_PARENT_SUBVOL=${SNAPSHOT_PARENT_SUBVOL:-"@snapshots"}
# 日志文件路径
export SNAPSHOT_LOG_PATH=${SNAPSHOT_LOG_PATH:-"/var/log/btrfs_snap"}
# 创建快照脚本
export CREATE_SNAP_SCRIPT="$SCRIPT_DIR/btrfs_snap_create.sh"
# 恢复快照脚本
export RESTORE_SNAP_SCRIPT="$SCRIPT_DIR/btrfs_snap_restore.sh"
# 删除快照脚本
export DELETE_SNAP_SCRIPT="$SCRIPT_DIR/btrfs_snap_delete.sh"
# 服务管理脚本
export SERVICE_SNAP_SCRIPT="$SCRIPT_DIR/btrfs_snap_service.sh"

# 拼接最终日志文件路径
LOG_FILE="${SNAPSHOT_LOG_PATH}/btrfs_snap.log"
# =================================================================================

# 日志输出函数（增加控制台输出，便于调试）
log() {
    local MSG="[$(date +%Y-%m-%d_%H:%M:%S)] [Btrfs快照管理] $1"
    # 同时输出到控制台和日志文件
    echo "$MSG"
    echo "$MSG" >> "$LOG_FILE"
}

# 创建快照脚本配置
# =========================
# 【小时快照】保留批次数量（24h×7天=168个）
export KEEP_HOURLY_BATCHES=168
# 【启动快照】保留批次数量（建议保留7-30个）
export KEEP_BOOT_BATCHES=7

# 要快照的子卷列表
export SRC_SUBVOLS=(
    "@"
    "@var"
    "@usr"
    "@home"
    "@data"
)

# 恢复快照脚本配置
# =========================
# 暂无

# 删除快照脚本配置
# =========================
# 暂无

# 显示帮助信息
show_help() {
    cat << EOF
版本：$VERSION
用法: $0 [选项] [快照参数]

选项：
  -c, --create     调用创建快照脚本，执行快照创建操作
  -r, --restore    调用恢复快照脚本，执行快照回滚操作
  -d, --delete     调用删除快照脚本，执行快照删除操作
  -h, --help       显示此帮助信息
      --install    安装服务+定时任务并启用
      --uninstall  停止并卸载服务+定时任务 
      --status     查看快照服务及定时任务状态

示例：
  $0 --create manual         # 创建手动快照
  $0 --create hourly         # 创建小时级快照
  $0 --restore               # 交互式恢复快照
  $0 --delete                # 交互式删除指定快照批次

注意：
  1. 需确保子脚本，存在且可执行
    ${CREATE_SNAP_SCRIPT}
    ${RESTORE_SNAP_SCRIPT}
    ${DELETE_SNAP_SCRIPT}
    ${SERVICE_SNAP_SCRIPT}
  2. 日志文件路径：${LOG_FILE}
EOF
}

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

# 调用创建或恢复（修复变量引用错误）
ACTION="${1:-}"

case "${ACTION}" in
    -c|--create)
        # 创建快照
        log "开始执行创建快照操作"
        # 检查创建脚本是否存在且可执行
        if [ ! -f "${CREATE_SNAP_SCRIPT}" ] || [ ! -x "${CREATE_SNAP_SCRIPT}" ]; then
            log "错误：创建快照脚本 ${CREATE_SNAP_SCRIPT} 不存在或不可执行！"
            exit 1  # 错误退出
        fi
        # 调用创建脚本，传递后续参数
        if ! bash "${CREATE_SNAP_SCRIPT}" "${@:2}"; then
            log "错误：创建快照失败！终止操作"
            exit 1
        fi
        log "创建快照操作执行完成"
        ;;
    -r|--restore)
        # 回滚快照
        log "开始执行恢复快照操作"
        # 检查恢复脚本是否存在且可执行
        if [ ! -f "${RESTORE_SNAP_SCRIPT}" ] || [ ! -x "${RESTORE_SNAP_SCRIPT}" ]; then
            log "错误：恢复快照脚本 ${RESTORE_SNAP_SCRIPT} 不存在或不可执行！"
            exit 1  # 错误退出
        fi
        # 调用恢复脚本，传递后续参数
        if ! bash "${RESTORE_SNAP_SCRIPT}" "${@:2}"; then
            log "错误：恢复快照失败！终止操作"
            exit 1
        fi
        log "恢复快照操作执行完成"
        ;;
    -d|--delete)
        # 删除快照
        log "开始执行删除快照操作"
        # 检查删除脚本是否存在且可执行
        if [ ! -f "${DELETE_SNAP_SCRIPT}" ] || [ ! -x "${DELETE_SNAP_SCRIPT}" ]; then
            log "错误：删除快照脚本 ${DELETE_SNAP_SCRIPT} 不存在或不可执行！"
            exit 1
        fi
        # 调用删除脚本，传递后续参数
        if ! bash "${DELETE_SNAP_SCRIPT}" "${@:2}"; then
            log "错误：删除快照失败！终止操作"
            exit 1
        fi
        log "删除快照操作执行完成"
        ;;
    --install|--uninstall|--status)
        # 管理服务
        log "开始执行服务管理操作"
        # 检查管理服务脚本是否存在且可执行
        if [ ! -f "${SERVICE_SNAP_SCRIPT}" ] || [ ! -x "${SERVICE_SNAP_SCRIPT}" ]; then
            log "错误：服务管理脚本 ${SERVICE_SNAP_SCRIPT} 不存在或不可执行！"
            exit 1
        fi
        # 调用管理服务脚本，传递后续参数
        if ! bash "${SERVICE_SNAP_SCRIPT}" "${@:1}"; then
            log "错误：服务管理脚本执行失败！终止操作"
            exit 1
        fi
        log "服务管理操作执行完成"
        ;;
    -h|--help|*)
        # 输出帮助
        show_help
        exit 0
        ;;
esac

exit 0
