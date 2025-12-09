#!/bin/bash
set -e

# 获取脚本所在目录的绝对路径
SCRIPT_DIR=$(dirname "$(realpath $0)")
# 项目根目录
ROOT_DIR=$(realpath "${SCRIPT_DIR}/..")
# NS3 仿真目录
NS3_SIM_DIR="${ROOT_DIR}/astra-sim-alibabacloud/extern/network_backend/ns3-interface/simulation"
# 目标二进制目录
TARGET_BIN_DIR="${ROOT_DIR}/bin"

echo "正在进入 NS3 仿真目录: ${NS3_SIM_DIR}"
cd "${NS3_SIM_DIR}"

echo "配置 NS3 为 optimized (Release) 模式..."
./ns3 configure -d optimized --enable-mtp

echo "开始编译..."
./ns3 build

echo "编译完成。正在更新软链接..."
# 确保 bin 目录存在
mkdir -p "${TARGET_BIN_DIR}"

# 删除旧的软链接（如果存在）
if [ -L "${TARGET_BIN_DIR}/SimAI_simulator" ]; then
    rm "${TARGET_BIN_DIR}/SimAI_simulator"
fi

# 创建新的软链接指向 optimized 版本
ln -s "${NS3_SIM_DIR}/build/scratch/ns3.36.1-AstraSimNetwork-optimized" "${TARGET_BIN_DIR}/SimAI_simulator"

echo "成功！Release 版本已链接到: ${TARGET_BIN_DIR}/SimAI_simulator"
