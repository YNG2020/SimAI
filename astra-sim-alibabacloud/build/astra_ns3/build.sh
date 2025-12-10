#!/bin/bash
# set -e
# Absolue path to this script
SCRIPT_DIR=$(dirname "$(realpath $0)")
echo $SCRIPT_DIR

# Absolute paths to useful directories
GEM5_DIR="${SCRIPT_DIR:?}"/../../extern/network_backend/garnet/gem5_astra/
ASTRA_SIM_DIR="${SCRIPT_DIR:?}"/../../astra-sim
INPUT_DIR="${SCRIPT_DIR:?}"/../../inputs
NS3_DIR="${SCRIPT_DIR:?}"/../../extern/network_backend/ns3-interface
NS3_APPLICATION="${NS3_DIR:?}"/simulation/src/applications/
SIM_LOG_DIR=/etc/astra-sim
BUILD_DIR="${SCRIPT_DIR:?}"/build/
RESULT_DIR="${SCRIPT_DIR:?}"/result/
BINARY="${BUILD_DIR}"/gem5.opt
ASTRA_SIM_LIB_DIR="${SCRIPT_DIR:?}"/build/AstraSim

# Functions
function setup {
    mkdir -p "${BUILD_DIR}"
    mkdir -p "${RESULT_DIR}"
}

function cleanup {
    echo $BUILD_DIR
    rm -rf "${BUILD_DIR}"
    rm -rf "${NS3_DIR}"/simulation/build
    rm -rf "${NS3_DIR}"/simulation/cmake-cache
    rm -rf "${NS3_APPLICATION}"/astra-sim 
    cd "${SCRIPT_DIR:?}"
}

function cleanup_result {
    rm -rf "${RESULT_DIR}"
}

function compile_astrasim {
    local build_type="Debug"
    if [ "$1" == "optimized" ] || [ "$1" == "release" ]; then
        build_type="Release"
    fi
    cd "${BUILD_DIR}" || exit
    cmake -DCMAKE_BUILD_TYPE="$build_type" ..
    make
}

function compile {
    # Only compile & Run the AstraSimNetwork ns3program
    # if [ ! -f '"${INPUT_DIR}"/inputs/config/SimAI.conf' ]; then
    #     echo ""${INPUT_DIR}"/config/SimAI.conf is not exist"
    #     cp "${INPUT_DIR}"/config/SimAI.conf "${SIM_LOG_DIR}"/config/SimAI.conf
    # fi
    local profile="debug"
    if [ "$1" == "release" ]; then
        profile="optimized"
    elif [ -n "$1" ]; then
        profile="$1"
    fi

    cp "${ASTRA_SIM_DIR}"/network_frontend/ns3/AstraSimNetwork.cc "${NS3_DIR}"/simulation/scratch/
    cp "${ASTRA_SIM_DIR}"/network_frontend/ns3/*.h "${NS3_DIR}"/simulation/scratch/
    
    # 仅当 astra-sim 目录不存在时才删除重建，否则只更新内容
    if [ ! -d "${NS3_APPLICATION}"/astra-sim ]; then
        cp -r "${ASTRA_SIM_DIR}" "${NS3_APPLICATION}"/
    else
        # 使用 rsync 或 cp -u 更新文件，避免不必要的重建
        cp -r "${ASTRA_SIM_DIR}"/* "${NS3_APPLICATION}"/astra-sim/
    fi
    
    cd "${NS3_DIR}/simulation"
    CC='gcc' CXX='g++' 
    ./ns3 configure -d "$profile" --enable-mtp
    ./ns3 build

    # 确保软链接指向正确的文件
    local target_bin="${NS3_DIR}/simulation/build/scratch/ns3.36.1-AstraSimNetwork-${profile}"
    if [ -f "$target_bin" ]; then
        echo "Build successful: $target_bin"
    else
        echo "Error: Build failed, binary not found at $target_bin"
        exit 1
    fi

    cd "${SCRIPT_DIR:?}"
}

function debug {
    cp "${ASTRA_SIM_DIR}"/network_frontend/ns3/AstraSimNetwork.cc "${NS3_DIR}"/simulation/scratch/
    cp "${ASTRA_SIM_DIR}"/network_frontend/ns3/*.h "${NS3_DIR}"/simulation/scratch/
    cd "${NS3_DIR}/simulation"
    CC='gcc-4.9' CXX='g++-4.9' 
    ./waf configure
    ./waf --run 'scratch/AstraSimNetwork' --command-template="gdb --args %s mix/config.txt"

    ./waf --run 'scratch/AstraSimNetwork mix/config.txt'

    cd "${SCRIPT_DIR:?}"
}

# Main Script
case "$1" in
-l|--clean)
    cleanup;;
-lr|--clean-result)
    cleanup
    cleanup_result;;
-d|--debug)
    setup
    debug;;
-c|--compile)
    setup
    compile_astrasim "$2"
    compile "$2";;
-r|--run)
    setup
    compile;;
-h|--help|*)
    printf "Prints help message";;
esac