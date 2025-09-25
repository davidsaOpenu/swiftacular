#!/bin/bash
set -e

BUILD_TYPE="RelWithDebInfo"
JOBS=$(nproc)
RAM=18 # GB

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_memory() {
    local available_ram=$(free -g | awk '/^Mem:/{print $2}')
    local required_ram=$RAM

    if [[ $available_ram -lt $required_ram ]]; then
        print_error "Insufficient RAM. Available: ${available_ram}GB, Required: ${required_ram}GB"
        exit 1
    fi

    print_status "RAM check passed. Available: ${available_ram}GB"
}

detect_os() {
    if [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]] || [[ -f /etc/fedora-release ]]; then
        OS_TYPE="redhat"
        PKG_MANAGER="dnf"
    elif [[ -f /etc/debian_version ]] || [[ -f /etc/ubuntu_version ]]; then
        OS_TYPE="debian"
        PKG_MANAGER="apt"
    else
        print_error "Unsupported operating system"
        exit 1
    fi

    print_status "Detected OS type: $OS_TYPE, Package manager: $PKG_MANAGER"
}

install_dev_tools() {
    print_status "Installing Development Tools..."

    case $PKG_MANAGER in
        "dnf")
            sudo $PKG_MANAGER update -y

            sudo $PKG_MANAGER groupinstall -y "Development Tools"
            ;;
        "apt")
            sudo apt update -y

            sudo apt install -y build-essential

            ;;
    esac

}

clone_ceph() {
    print_status "Cloning Ceph repository to tmpfs..."

    rm -rf ceph

    git clone https://github.com/ceph/ceph.git

    cd ceph

    print_status "Updating git submodules..."
    git submodule update --init --recursive --progress

    cd ..
}

install_ceph_dependencies() {
    print_status "Installing Ceph-specific dependencies..."

    cd "ceph"

    ./install-deps.sh

    cd ..
}

configure_build() {
    print_status "Configuring build with CMake..."

    cd "ceph"

    export ARGS="-DCMAKE_BUILD_TYPE=$BUILD_TYPE -DWITH_BLUESTORE=ON -DWITH_TESTS=ON"

    ./do_cmake.sh

    cd ..
}

build_ceph() {
    print_status "Building Ceph with $JOBS parallel jobs..."

    cd "ceph/build"

    local max_memory_jobs=$(($(free -g | awk '/^Mem:/{print $7}') / 3))  # 3GB per job
    local safe_jobs=$((JOBS < max_memory_jobs ? JOBS : max_memory_jobs))

    if [[ $safe_jobs -lt $JOBS ]]; then
        print_warning "Reducing jobs from $JOBS to $safe_jobs due to memory constraints"
        JOBS=$safe_jobs
    fi

    print_status "Building with $JOBS parallel jobs..."

    ninja -j$JOBS

    cd ../..
}

build_objectstore_tests() {
    print_status "Building object store related tests..."

    cd "ceph/build"

    ninja -j$JOBS ceph_test_objectstore
    ninja -j$JOBS unittest_bluestore_types

    cd ../..
}

run_objectstore_tests() {
    print_status "Running object store related tests..."

    cd "ceph/build/bin"

    ./ceph_test_objectstore
    ./unittest_bluestore_types

    cd ../../..
}

print_status "Starting Ceph BlueStore build process..."
print_status "Build type: $BUILD_TYPE"
print_status "Parallel jobs: $JOBS"
detect_os
check_memory
install_dev_tools
clone_ceph
install_ceph_dependencies
configure_build
build_ceph
build_objectstore_tests
run_objectstore_tests
