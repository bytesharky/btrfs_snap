#!/bin/bash
# 增强健壮性：-e(错误退出) -u(未定义变量退出) -o pipefail(管道失败传递)
set -euo pipefail
# 版本号
VERSION=1.0.0
# 获取脚本自身的绝对路径（处理软链接）
SCRIPT_PATH=$(readlink -f "$0")
# 从绝对路径中提取目录部分
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# ==================== 可配置变量（建议在主脚本修改）====================
# 基础服务名（不含 .service 后缀）
SERVICE_BASE="btrfs-snap"
# 开机自启的服务实例名称
BOOT_SERVICE_INSTANCE="${SERVICE_BASE}-boot.service"
# 定时任务的服务实例名称
HOURLY_SERVICE_INSTANCE="${SERVICE_BASE}-hourly.service"
# Timer 定时任务名称
TIMER_NAME="${SERVICE_BASE}.timer"
# 服务文件安装路径
BOOT_SERVICE_FILE="/etc/systemd/system/${BOOT_SERVICE_INSTANCE}"
HOURLY_SERVICE_FILE="/etc/systemd/system/${HOURLY_SERVICE_INSTANCE}"
TIMER_FILE="/etc/systemd/system/${TIMER_NAME}"
# 你的脚本实际路径
SCRIPT_PATH="$SCRIPT_DIR/btrfs_snap.sh"
# 日志文件路径
LOG_FILE="/var/log/btrfs_snap.log"
# 目标磁盘路径
DISK_PATH="/dev/nvme0n1p2"
# =======================================================================

# 定义服务模板内容
BOOT_SERVICE_TEMPLATE=$(cat <<EOF
[Unit]
Description=Btrfs boot 快照服务 
After=multi-user.target local-fs.target
ConditionPathExists=${DISK_PATH}

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/bin/bash ${SCRIPT_PATH} --create boot
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
TimeoutSec=300
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/log
ReadWritePaths=/var/log/btrfs_snap
ReadWritePaths=/run

[Install]
WantedBy=multi-user.target
EOF
)

HOURLY_SERVICE_TEMPLATE=$(cat <<EOF
[Unit]
Description=Btrfs hourly 快照服务 
After=multi-user.target local-fs.target
ConditionPathExists=${DISK_PATH}

[Service]
Type=oneshot
User=root
Group=root
ExecStart=/bin/bash ${SCRIPT_PATH} --create hourly
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
TimeoutSec=300
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/log
ReadWritePaths=/var/log/btrfs_snap
ReadWritePaths=/run

[Install]
WantedBy=multi-user.target
EOF
)
# 定义 Timer 定时任务模板
TIMER_TEMPLATE=$(cat <<EOF
[Unit]
Description=每小时执行一次 Btrfs 快照任务

[Timer]
# 每小时执行一次
OnCalendar=hourly
# 随机延迟 0-60 秒，避免整点资源抢占
RandomizedDelaySec=60
# 错过执行时间不补
Persistent=false
# 绑定正确的定时服务实例
Unit=${HOURLY_SERVICE_INSTANCE}

[Install]
WantedBy=timers.target
EOF
)

# 显示帮助信息
show_help() {
    echo "用法: $0 [COMMAND]"
    echo "管理 Btrfs 快照服务及每小时定时任务"
    echo ""
    echo "命令:"
    echo "  -i, --install    安装服务+定时任务并启用"
    echo "  -r, --uninstall  停止并卸载服务+定时任务"
    echo "      --status     查看快照服务及定时任务状态"
    echo "  -h, --help       显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 --install   # 安装服务和定时任务"
    echo "  $0 --uninstall # 卸载服务和定时任务"
    echo "  $0 --status    # 查看运行状态"
}

# 检查是否为 root 用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "错误: 必须以 root 权限运行此脚本（使用 sudo）"
        exit 1
    fi
}

# 查看快照服务状态
check_snap_status() {
    echo "======= Btrfs 快照服务状态汇总 ======="
    echo ""
    echo "● 开机快照服务状态"
    systemctl status "${BOOT_SERVICE_INSTANCE}" --no-pager -all || echo ""
    echo ""
    echo "● 定时任务状态"
    systemctl list-timers "${TIMER_NAME}" --no-pager -all || echo ""
    echo ""
    echo "● 最近快照执行日志（最后 10 行）"
    if [ -f "${LOG_FILE}" ]; then
        tail -n 10 "${LOG_FILE}"
    else
        echo "日志文件不存在: ${LOG_FILE}"
    fi
    echo ""
    echo "======================================"
}

# 安装服务和定时任务
install_service() {
    check_root
    
    # 检查脚本文件是否存在
    if [ ! -f "${SCRIPT_PATH}" ]; then
        echo "警告: 脚本文件 ${SCRIPT_PATH} 不存在！"
        read -p "是否继续安装（运行时会失败）？[y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "安装已取消"
            exit 1
        fi
    fi

    # 生成服务文件
    echo "${BOOT_SERVICE_TEMPLATE}" > "${BOOT_SERVICE_FILE}"
    echo "已生成启动快照服务文件: ${BOOT_SERVICE_FILE}"

    echo "${HOURLY_SERVICE_TEMPLATE}" > "${HOURLY_SERVICE_FILE}"
    echo "已生成小时快照服务文件: ${HOURLY_SERVICE_FILE}"


    # 生成 Timer 定时任务文件
    echo "${TIMER_TEMPLATE}" > "${TIMER_FILE}"
    echo "已生成定时任务文件: ${TIMER_FILE}"

    # 重新加载 systemd 配置
    systemctl daemon-reload
    echo "已重载 systemd 配置"

    # 启用开机自启服务实例（传 boot 参数），立即执行
    systemctl enable --now "${BOOT_SERVICE_INSTANCE}" >/dev/null 2>&1 || true
    echo "已启用开机快照服务（参数: boot），并立即执行"

    # 启用定时任务
    systemctl enable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
    echo "已启用每小时定时快照任务（参数: hourly）"

    echo "安装完成！"
}

# 卸载服务和定时任务
uninstall_service() {
    check_root
    
    # 停止定时任务和两个服务实例
    systemctl stop "${TIMER_NAME}" >/dev/null 2>&1 || true
    systemctl stop "${BOOT_SERVICE_INSTANCE}" >/dev/null 2>&1 || true
    systemctl stop "${HOURLY_SERVICE_INSTANCE}" >/dev/null 2>&1 || true
    echo "已停止服务和定时任务"

    # 禁用相关服务和定时任务
    systemctl disable "${TIMER_NAME}" >/dev/null 2>&1 || true
    systemctl disable "${BOOT_SERVICE_INSTANCE}" >/dev/null 2>&1 || true
    systemctl disable "${HOURLY_SERVICE_INSTANCE}" >/dev/null 2>&1 || true
    echo "已禁用服务和定时任务"

    # 删除文件
    rm -f "${BOOT_SERVICE_FILE}" "{$HOURLY_SERVICE_FILE}" "${TIMER_FILE}"
    echo "已删除服务文件和定时任务文件"

    # 重载 systemd 配置并清理失效服务
    systemctl daemon-reload
    systemctl reset-failed
    echo "已重载 systemd 配置"

    # 可选：删除日志文件
    # rm -f "${LOG_FILE}"
    # echo "已删除日志文件"

    echo "卸载完成！"
}

# 主逻辑
ACTION=${1:-}
case $ACTION in
    -i|--install)
        install_service
        ;;
    -r|--uninstall)
        uninstall_service
        ;;
    --status)
        check_snap_status
        ;;
    -h|--help|*)
        show_help
        ;;
esac

exit 0
