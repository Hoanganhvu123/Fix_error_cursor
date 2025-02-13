#!/bin/bash

# 设置错误处理
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 获取当前用户
get_current_user() {
    if [ "$EUID" -eq 0 ]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

CURRENT_USER=$(get_current_user)
if [ -z "$CURRENT_USER" ]; then
    log_error "无法获取用户名"
    exit 1
fi

# 定义配置文件路径
STORAGE_FILE="$HOME/Library/Application Support/Cursor/User/globalStorage/storage.json"
BACKUP_DIR="$HOME/Library/Application Support/Cursor/User/globalStorage/backups"

# 检查权限
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 sudo 运行此脚本"
        echo "示例: sudo $0"
        exit 1
    fi
}

# 检查并关闭 Cursor 进程
check_and_kill_cursor() {
    log_info "检查 Cursor 进程..."
    
    local attempt=1
    local max_attempts=5
    
    # 函数：获取进程详细信息
    get_process_details() {
        local process_name="$1"
        log_debug "正在获取 $process_name 进程详细信息："
        ps aux | grep -i "$process_name" | grep -v grep
    }
    
    while [ $attempt -le $max_attempts ]; do
        CURSOR_PIDS=$(pgrep -i "cursor" || true)
        
        if [ -z "$CURSOR_PIDS" ]; then
            log_info "未发现运行中的 Cursor 进程"
            return 0
        fi
        
        log_warn "发现 Cursor 进程正在运行"
        get_process_details "cursor"
        
        log_warn "尝试关闭 Cursor 进程..."
        
        if [ $attempt -eq $max_attempts ]; then
            log_warn "尝试强制终止进程..."
            kill -9 $CURSOR_PIDS 2>/dev/null || true
        else
            kill $CURSOR_PIDS 2>/dev/null || true
        fi
        
        sleep 1
        
        if ! pgrep -i "cursor" > /dev/null; then
            log_info "Cursor 进程已成功关闭"
            return 0
        fi
        
        log_warn "等待进程关闭，尝试 $attempt/$max_attempts..."
        ((attempt++))
    done
    
    log_error "在 $max_attempts 次尝试后仍无法关闭 Cursor 进程"
    get_process_details "cursor"
    log_error "请手动关闭进程后重试"
    exit 1
}

# 备份系统 ID
backup_system_id() {
    log_info "正在备份系统 ID..."
    local system_id_file="$BACKUP_DIR/system_id.backup_$(date +%Y%m%d_%H%M%S)"
    
    # 获取并备份 IOPlatformExpertDevice 信息
    {
        echo "# Original System ID Backup" > "$system_id_file"
        echo "## IOPlatformExpertDevice Info:" >> "$system_id_file"
        ioreg -rd1 -c IOPlatformExpertDevice >> "$system_id_file"
        
        chmod 444 "$system_id_file"
        chown "$CURRENT_USER" "$system_id_file"
        log_info "系统 ID 已备份到: $system_id_file"
    } || {
        log_error "备份系统 ID 失败"
        return 1
    }
}

# 备份配置文件
backup_config() {
    if [ ! -f "$STORAGE_FILE" ]; then
        log_warn "配置文件不存在，跳过备份"
        return 0
    fi
    
    mkdir -p "$BACKUP_DIR"
    local backup_file="$BACKUP_DIR/storage.json.backup_$(date +%Y%m%d_%H%M%S)"
    
    if cp "$STORAGE_FILE" "$backup_file"; then
        chmod 644 "$backup_file"
        chown "$CURRENT_USER" "$backup_file"
        log_info "配置已备份到: $backup_file"
    else
        log_error "备份失败"
        exit 1
    fi
}

# 生成随机 ID
generate_random_id() {
    # 生成32字节(64个十六进制字符)的随机数
    openssl rand -hex 32
}

# 生成随机 UUID
generate_uuid() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

# 生成新的配置
generate_new_config() {
    # 检查配置文件是否存在
    if [ ! -f "$STORAGE_FILE" ]; then
        log_error "未找到配置文件: $STORAGE_FILE"
        log_warn "请先安装并运行一次 Cursor 后再使用此脚本"
        exit 1
    fi
    
    # 修改系统 ID
    log_info "正在修改系统 ID..."
    
    # 备份当前系统 ID
    backup_system_id
    
    # 生成新的系统 UUID
    local new_system_uuid=$(uuidgen)
    
    # 尝试修改系统 UUID (需要用户确认)
    log_warn "注意：修改系统 UUID 需要重启系统才能生效"
    log_warn "是否要修改系统 UUID？(y/N)"
    read -r choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        sudo nvram SystemUUID="$new_system_uuid"
        log_info "系统 UUID 已更新，请重启系统以应用更改"
    else
        log_info "跳过系统 UUID 修改"
    fi
    
    # 将 auth0|user_ 转换为字节数组的十六进制
    local prefix_hex=$(echo -n "auth0|user_" | xxd -p)
    local random_part=$(generate_random_id)
    local machine_id="${prefix_hex}${random_part}"
    
    local mac_machine_id=$(generate_random_id)
    local device_id=$(generate_uuid | tr '[:upper:]' '[:lower:]')
    local sqm_id="{$(generate_uuid | tr '[:lower:]' '[:upper:]')}"
    
    # 修改现有文件
    sed -i '' -e "s/\"telemetry\.machineId\":[[:space:]]*\"[^\"]*\"/\"telemetry.machineId\": \"$machine_id\"/" "$STORAGE_FILE"
    sed -i '' -e "s/\"telemetry\.macMachineId\":[[:space:]]*\"[^\"]*\"/\"telemetry.macMachineId\": \"$mac_machine_id\"/" "$STORAGE_FILE"
    sed -i '' -e "s/\"telemetry\.devDeviceId\":[[:space:]]*\"[^\"]*\"/\"telemetry.devDeviceId\": \"$device_id\"/" "$STORAGE_FILE"
    sed -i '' -e "s/\"telemetry\.sqmId\":[[:space:]]*\"[^\"]*\"/\"telemetry.sqmId\": \"$sqm_id\"/" "$STORAGE_FILE"

    # 设置文件权限和所有者
    chmod 444 "$STORAGE_FILE"  # 改为只读权限
    chown "$CURRENT_USER" "$STORAGE_FILE"
    
    # 验证权限设置
    if [ -w "$STORAGE_FILE" ]; then
        log_warn "无法设置只读权限，尝试使用其他方法..."
        chattr +i "$STORAGE_FILE" 2>/dev/null || true
    else
        log_info "成功设置文件只读权限"
    fi
    
    echo
    log_info "已更新配置:"
    log_debug "machineId: $machine_id"
    log_debug "macMachineId: $mac_machine_id"
    log_debug "devDeviceId: $device_id"
    log_debug "sqmId: $sqm_id"
}

# 显示文件树结构
show_file_tree() {
    local base_dir=$(dirname "$STORAGE_FILE")
    echo
    log_info "文件结构:"
    echo -e "${BLUE}$base_dir${NC}"
    echo "├── globalStorage"
    echo "│   ├── storage.json (已修改)"
    echo "│   └── backups"
    
    # 列出备份文件
    if [ -d "$BACKUP_DIR" ]; then
        local backup_files=("$BACKUP_DIR"/*)
        if [ ${#backup_files[@]} -gt 0 ]; then
            for file in "${backup_files[@]}"; do
                if [ -f "$file" ]; then
                    echo "│       └── $(basename "$file")"
                fi
            done
        else
            echo "│       └── (空)"
        fi
    fi
    echo
}

# 显示公众号信息
show_follow_info() {
    echo
    echo -e "${GREEN}================================${NC}"
    echo -e "${YELLOW}  关注公众号【煎饼果子卷AI】一起交流更多Cursor技巧和AI知识 ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo
}

# 询问是否要禁用自动更新
disable_auto_update() {
    echo
    log_warn "是否要禁用 Cursor 自动更新功能？"
    echo "0) 否 - 保持默认设置 (按回车键)"
    echo "1) 是 - 禁用自动更新"
    read -r choice
    
    if [ "$choice" = "1" ]; then
        echo
        log_info "正在处理自动更新..."
        local updater_path="$HOME/Library/Application Support/cursor-updater"
        
        # 定义手动设置教程
        show_manual_guide() {
            echo
            log_warn "自动设置失败,请尝试手动操作："
            echo -e "${YELLOW}手动禁用更新步骤：${NC}"
            echo "1. 打开终端(Terminal)"
            echo "2. 复制粘贴以下命令："
            echo -e "${BLUE}rm -rf \"$updater_path\" && touch \"$updater_path\" && chmod 444 \"$updater_path\"${NC}"
            echo
            echo -e "${YELLOW}如果上述命令提示权限不足，请使用 sudo：${NC}"
            echo -e "${BLUE}sudo rm -rf \"$updater_path\" && sudo touch \"$updater_path\" && sudo chmod 444 \"$updater_path\"${NC}"
            echo
            echo -e "${YELLOW}验证方法：${NC}"
            echo "1. 运行命令：ls -l \"$updater_path\""
            echo "2. 确认文件权限为 r--r--r--"
            echo
            log_warn "完成后请重启 Cursor"
        }
        
        if [ -d "$updater_path" ]; then
            rm -rf "$updater_path" 2>/dev/null || {
                log_error "删除 cursor-updater 目录失败"
                show_manual_guide
                return 1
            }
            log_info "成功删除 cursor-updater 目录"
        fi
        
        touch "$updater_path" 2>/dev/null || {
            log_error "创建阻止文件失败"
            show_manual_guide
            return 1
        }
        
        chmod 444 "$updater_path" 2>/dev/null && \
        chown "$CURRENT_USER" "$updater_path" 2>/dev/null || {
            log_error "设置文件权限失败"
            show_manual_guide
            return 1
        }
        
        # 验证设置是否成功
        if [ ! -f "$updater_path" ] || [ -w "$updater_path" ]; then
            log_error "验证失败：文件权限设置可能未生效"
            show_manual_guide
            return 1
        fi
        
        log_info "成功禁用自动更新"
    else
        log_info "保持默认设置，不进行更改"
    fi
}

# 主函数
main() {
    clear
    # 显示 CURSOR Logo
    echo -e "
    ██████╗██╗   ██╗██████╗ ███████╗ ██████╗ ██████╗ 
   ██╔════╝██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔══██╗
   ██║     ██║   ██║██████╔╝███████╗██║   ██║██████╔╝
   ██║     ██║   ██║██╔══██╗╚════██║██║   ██║██╔══██╗
   ╚██████╗╚██████╔╝██║  ██║███████║╚██████╔╝██║  ██║
    ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝
    "
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}      Cursor ID 修改工具         ${NC}"
    echo -e "${BLUE}================================${NC}"
    echo
    echo -e "${YELLOW}[重要提示]${NC} 本工具仅支持 Cursor v0.44.11 及以下版本"
    echo -e "${YELLOW}[重要提示]${NC} 最新的 0.45.x 版本暂不支持"
    echo
    
    check_permissions
    check_and_kill_cursor
    backup_config
    generate_new_config
    
    echo
    log_info "操作完成！"
    show_file_tree
    show_follow_info
    log_info "请重启 Cursor 以应用新的配置"
    
    # 询问是否要禁用自动更新
    disable_auto_update
}

# 执行主函数
main
