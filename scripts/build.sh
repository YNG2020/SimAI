#!/bin/bash

SCRIPT_DIR=$(dirname "$(realpath $0)")
ROOT_DIR=$(realpath "${SCRIPT_DIR:?}"/..)
NS3_DIR="${ROOT_DIR:?}"/ns-3-alibabacloud
SIMAI_DIR="${ROOT_DIR:?}"/astra-sim-alibabacloud
SOURCE_NS3_BIN_DIR="${SIMAI_DIR:?}"/extern/network_backend/ns3-interface/simulation/build/scratch/ns3.36.1-AstraSimNetwork-debug
SOURCE_ANA_BIN_DIR="${SIMAI_DIR:?}"/build/simai_analytical/build/simai_analytical/SimAI_analytical
SOURCE_PHY_BIN_DIR="${SIMAI_DIR:?}"/build/simai_phy/build/simai_phynet/SimAI_phynet

TARGET_BIN_DIR="${SCRIPT_DIR:?}"/../bin
function compile {
    local option="$1" 
    local profile="$2"
    local ns3_profile="debug"
    if [ "$profile" == "release" ] || [ "$profile" == "optimized" ]; then
        ns3_profile="optimized"
    fi

    case "$option" in
    "ns3")
        mkdir -p "${TARGET_BIN_DIR:?}"
        
        # 仅当 ns3-interface 不存在时才进行初始化复制
        if [ ! -d "${SIMAI_DIR:?}/extern/network_backend/ns3-interface/" ]; then
            mkdir -p "${SIMAI_DIR:?}"/extern/network_backend/ns3-interface
            cp -r "${NS3_DIR:?}"/* "${SIMAI_DIR:?}"/extern/network_backend/ns3-interface
        fi

        # 更新软链接前先删除旧的
        if [ -L "${TARGET_BIN_DIR:?}/SimAI_simulator" ]; then
            rm -rf "${TARGET_BIN_DIR:?}"/SimAI_simulator
        fi
        
        cd "${SIMAI_DIR:?}"
        # 移除 -lr (clean-result) 以保留构建产物
        # ./build.sh -lr ns3 
        ./build.sh -c ns3 "$ns3_profile"
        local source_bin="${SIMAI_DIR:?}/extern/network_backend/ns3-interface/simulation/build/scratch/ns3.36.1-AstraSimNetwork-${ns3_profile}"
        
        # 检查源文件是否存在
        if [ ! -f "$source_bin" ]; then
            echo "Error: Binary not found at $source_bin"
            exit 1
        fi
        
        ln -s "${source_bin}" "${TARGET_BIN_DIR:?}"/SimAI_simulator;;
    "phy")
        mkdir -p "${TARGET_BIN_DIR:?}"
        if [ -L "${TARGET_BIN_DIR:?}/SimAI_phynet" ]; then
            rm -rf "${TARGET_BIN_DIR:?}"/SimAI_phynet
        fi
        cd "${SIMAI_DIR:?}"
        ./build.sh -lr phy
        ./build.sh -c phy "$profile"
        ln -s "${SOURCE_PHY_BIN_DIR:?}" "${TARGET_BIN_DIR:?}"/SimAI_phynet;;
    "analytical")
        mkdir -p "${TARGET_BIN_DIR:?}"
        mkdir -p "${ROOT_DIR:?}"/results
        if [ -L "${TARGET_BIN_DIR:?}/SimAI_analytical" ]; then
            rm -rf "${TARGET_BIN_DIR:?}"/SimAI_analytical
        fi
        cd "${SIMAI_DIR:?}"
        ./build.sh -lr analytical
        ./build.sh -c analytical "$profile"
        ln -s "${SOURCE_ANA_BIN_DIR:?}" "${TARGET_BIN_DIR:?}"/SimAI_analytical;;
    esac
}

function cleanup_build {
    local option="$1"
    case "$option" in
    "ns3")
        if [ -L "${TARGET_BIN_DIR:?}/SimAI_simulator" ]; then
            rm -rf "${TARGET_BIN_DIR:?}"/SimAI_simulator
        fi
        rm -rf "${SIMAI_DIR:?}"/extern/network_backend/ns3-interface/
        cd "${SIMAI_DIR:?}"
        ./build.sh -lr ns3;;
    "phy")
        if [ -L "${TARGET_BIN_DIR:?}/SimAI_phynet" ]; then
            rm -rf "${TARGET_BIN_DIR:?}"/SimAI_phynet
        fi
        cd "${SIMAI_DIR:?}"
        ./build.sh -lr phy;;
    "analytical")
        if [ -L "${TARGET_BIN_DIR:?}/SimAI_analytical" ]; then
            rm -rf "${TARGET_BIN_DIR:?}"/SimAI_analytical
        fi
        cd "${SIMAI_DIR:?}"
        ./build.sh -lr analytical;;
    esac
}

# Main Script
case "$1" in
-l|--clean)
    cleanup_build "$2";;
-c|--compile)
    compile "$2" "$3";;
-h|--help|*)
    printf -- "help message\n"
    printf -- "-c|--compile mode supported ns3/phy/analytical  (example:./build.sh -c ns3)\n"
    printf -- "-l|--clean  (example:./build.sh -l ns3)\n"
    printf -- "-lr|--clean-result mode  (example:./build.sh -lr ns3)\n"
esac