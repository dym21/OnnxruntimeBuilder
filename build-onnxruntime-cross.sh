#!/bin/bash
# build onnxruntime for multiple architectures using cross-compilation
# supports: x86_64, aarch64, loongarch64, mips64el

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function is_cmd_exist() {
    retval=""
    if ! command -v $1 >/dev/null 2>&1; then
        retval="false"
    else
        retval="true"
    fi
    echo "$retval"
}

# 获取脚本所在目录
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 架构配置
declare -A ARCH_NAMES
declare -A TOOLCHAIN_FILES

ARCH_NAMES["x86_64"]="x86_64"
ARCH_NAMES["aarch64"]="aarch64"
ARCH_NAMES["loongarch64"]="loongarch64"
ARCH_NAMES["mips64el"]="mips64el"

TOOLCHAIN_FILES["x86_64"]="/opt/zftoolchain/toolchain_x64.cmake"
TOOLCHAIN_FILES["aarch64"]="/opt/zftoolchain/toolchain_aarch64.cmake"
TOOLCHAIN_FILES["loongarch64"]="/opt/zftoolchain/toolchain_loongarch64.cmake"
TOOLCHAIN_FILES["mips64el"]="/opt/zftoolchain/toolchain_mips64.cmake"

# 默认参数
BUILD_TYPE=Release
NUM_THREADS=$(nproc)
TARGET_ARCH=""
BUILD_ALL=false

# 显示帮助
function show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -a ARCH     Target architecture: x86_64, aarch64, loongarch64, mips64el"
    echo "  -t TYPE     Build type: Release (default) or Debug"
    echo "  -j N        Number of parallel build threads (default: auto)"
    echo "  -all        Build for all supported architectures"
    echo "  -h          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -a x86_64                    # Build for x86_64"
    echo "  $0 -a aarch64 -t Debug          # Build for aarch64 in Debug mode"
    echo "  $0 -all                         # Build for all architectures"
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -a)
            TARGET_ARCH="$2"
            shift 2
            ;;
        -t)
            BUILD_TYPE="$2"
            shift 2
            ;;
        -j)
            NUM_THREADS="$2"
            shift 2
            ;;
        -all)
            BUILD_ALL=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# 验证参数
if [ "$BUILD_ALL" = false ] && [ -z "$TARGET_ARCH" ]; then
    log_error "Please specify target architecture with -a or use -all to build all architectures"
    show_help
    exit 1
fi

# 检查 onnxruntime 源码
if [ ! -d "$DIR/onnxruntime" ]; then
    log_warn "onnxruntime source not found, cloning..."
    git clone --recursive https://github.com/Microsoft/onnxruntime.git "$DIR/onnxruntime"
fi

# 检查必要的命令
if [ "$(is_cmd_exist cmake)" == "false" ]; then
    log_error "cmake is not installed"
    exit 1
fi

if [ "$(is_cmd_exist python3)" == "false" ]; then
    log_error "python3 is not installed"
    exit 1
fi

# 使用 uv 运行 Python 构建脚本
function run_build_with_uv() {
    local arch=$1
    local build_dir=$2
    local toolchain_file=$3

    log_info "Building for $arch using uv..."

    # 创建 uv 虚拟环境（如果不存在）
    if [ ! -d "$DIR/.venv" ]; then
        log_info "Creating uv virtual environment..."
        uv venv "$DIR/.venv"
    fi

    # 安装必要的 Python 包
    log_info "Installing Python dependencies..."
    uv pip install --python "$DIR/.venv/bin/python" -r "$DIR/onnxruntime/tools/ci_build/requirements.txt" 2>/dev/null || true

    # 根据架构设置编译器标志
    local extra_cflags=""
    local extra_cxxflags=""
    local extra_asmflags=""
    # AVX-VNNI/AVX512/AMX support is removed via cmake source modifications
    # No need for extra compiler flags to disable them

    # 运行构建
    uv run --python "$DIR/.venv/bin/python" "$DIR/onnxruntime/tools/ci_build/build.py" \
        --build_dir "$build_dir" \
        --allow_running_as_root \
        --config "$BUILD_TYPE" \
        --parallel "$NUM_THREADS" \
        --skip_tests \
        --build_shared_lib \
        --compile_no_warning_as_error \
        --cmake_extra_defines \
            CMAKE_TOOLCHAIN_FILE="$toolchain_file" \
            CMAKE_INSTALL_PREFIX=./install \
            onnxruntime_BUILD_UNIT_TESTS=OFF \
            onnxruntime_USE_OPENMP=OFF \
            onnxruntime_USE_CUDA=OFF \
            onnxruntime_USE_ROCM=OFF \
            onnxruntime_USE_TENSORRT=OFF \
            onnxruntime_USE_DNNL=OFF \
            onnxruntime_USE_MIGRAPHX=OFF \
            onnxruntime_USE_NCCL=OFF \
            onnxruntime_USE_OPENVINO=OFF \
            onnxruntime_USE_NUPHAR=OFF \
            onnxruntime_USE_VITISAI=OFF \
            onnxruntime_USE_ACL=OFF \
            onnxruntime_USE_ARMNN=OFF \
            onnxruntime_USE_XNNPACK=OFF \
            onnxruntime_USE_CANN=OFF \
            onnxruntime_USE_KLEIDIAI=OFF \
            onnxruntime_USE_SVE=OFF \
            onnxruntime_ENABLE_CPU_FP16_OPS=OFF \
            CMAKE_CXX_STANDARD=20 \
            CMAKE_C_FLAGS="$extra_cflags" \
            CMAKE_CXX_FLAGS="$extra_cxxflags" \
            CMAKE_ASM_FLAGS="$extra_asmflags"
}

# 收集共享库
function collect_shared_lib() {
    local build_root=$1
    local arch=$2

    pushd "$build_root/$BUILD_TYPE" > /dev/null

    if [ -d "install/bin" ]; then
        rm -r -f install/bin
    fi

    if [ -d "install/include/onnxruntime" ]; then
        mv install/include/onnxruntime/* install/include
        rm -rf install/include/onnxruntime
    fi

    # 创建 CMake 配置文件
    cat > install/OnnxRuntimeConfig.cmake << EOF
set(OnnxRuntime_INCLUDE_DIRS "\${CMAKE_CURRENT_LIST_DIR}/include")
include_directories(\${OnnxRuntime_INCLUDE_DIRS})
link_directories(\${CMAKE_CURRENT_LIST_DIR}/lib)
set(OnnxRuntime_LIBS onnxruntime)
EOF

    popd > /dev/null
}

# 合并静态库
function combine_static_libs() {
    local build_root=$1
    local arch=$2

    pushd "$build_root/$BUILD_TYPE" > /dev/null

    if [ ! -f "CMakeFiles/onnxruntime.dir/link.txt" ]; then
        log_warn "link.txt not found, skipping static lib collection"
        popd > /dev/null
        return
    fi

    if [ -d "install-static" ]; then
        rm -r -f install-static
    fi
    mkdir -p install-static/lib

    if [ -d "install/include" ]; then
        cp -r install/include install-static
    fi

    local all_link=$(cat CMakeFiles/onnxruntime.dir/link.txt)
    local link=${all_link#*onnxruntime.dir}
    local regex="lib.*\.a$"
    local static_path="${PWD}/install-static"
    local lib_path="${static_path}/lib"

    echo "create ${lib_path}/libonnxruntime.a" > "${static_path}/libonnxruntime.mri"

    for var in $link; do
        if [[ ${var} =~ ${regex} ]]; then
            echo "addlib ${PWD}/${var}" >> "${static_path}/libonnxruntime.mri"
        fi
    done

    echo "save" >> "${static_path}/libonnxruntime.mri"
    echo "end" >> "${static_path}/libonnxruntime.mri"

    ar -M < "${static_path}/libonnxruntime.mri" 2>/dev/null || {
        log_warn "Failed to combine static libraries with ar -M, copying individual libs instead"
        # 备选方案：直接复制静态库
        for var in $link; do
            if [[ ${var} =~ ${regex} ]]; then
                cp "${PWD}/${var}" "${lib_path}/" 2>/dev/null || true
            fi
        done
    }

    # 创建 CMake 配置文件
    cat > install-static/OnnxRuntimeConfig.cmake << EOF
set(OnnxRuntime_INCLUDE_DIRS "\${CMAKE_CURRENT_LIST_DIR}/include")
include_directories(\${OnnxRuntime_INCLUDE_DIRS})
link_directories(\${CMAKE_CURRENT_LIST_DIR}/lib)
set(OnnxRuntime_LIBS onnxruntime)
EOF

    cp CMakeFiles/onnxruntime.dir/link.txt install-static/link.log

    popd > /dev/null
}

# 构建单个架构
function build_arch() {
    local arch=$1
    local toolchain_file="${TOOLCHAIN_FILES[$arch]}"

    if [ ! -f "$toolchain_file" ]; then
        log_error "Toolchain file not found: $toolchain_file"
        return 1
    fi

    log_info "========================================="
    log_info "Building ONNX Runtime for $arch"
    log_info "Build type: $BUILD_TYPE"
    log_info "Toolchain: $toolchain_file"
    log_info "========================================="

    local build_root="$DIR/build-${arch}"

    # 运行构建
    run_build_with_uv "$arch" "$build_root" "$toolchain_file"

    # 检查构建结果
    if [ ! -d "$build_root/$BUILD_TYPE" ]; then
        log_error "Build failed for $arch - build directory not found"
        return 1
    fi

    # 安装
    pushd "$build_root/$BUILD_TYPE" > /dev/null
    cmake --install .

    if [ ! -d "install" ]; then
        log_error "CMake install failed for $arch"
        popd > /dev/null
        return 1
    fi

    # 收集库文件
    collect_shared_lib "$build_root" "$arch"
    combine_static_libs "$build_root" "$arch"

    popd > /dev/null

    log_info "========================================="
    log_info "Build completed for $arch"
    log_info "Output: $build_root/$BUILD_TYPE/install"
    log_info "========================================="
}

# 主构建流程
if [ "$BUILD_ALL" = true ]; then
    log_info "Building for all architectures..."
    for arch in x86_64 aarch64 loongarch64 mips64el; do
        build_arch "$arch" || log_warn "Build failed for $arch"
    done
else
    # 验证架构
    if [ -z "${ARCH_NAMES[$TARGET_ARCH]}" ]; then
        log_error "Unsupported architecture: $TARGET_ARCH"
        log_error "Supported architectures: x86_64, aarch64, loongarch64, mips64el"
        exit 1
    fi
    build_arch "$TARGET_ARCH"
fi

log_info "All builds completed!"
