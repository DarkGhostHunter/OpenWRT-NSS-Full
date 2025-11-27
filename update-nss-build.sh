#!/usr/bin/env bash

# ==============================================================================
# OpenWRT Custom Build Script
# Based on: jkool702/openwrt-custom-builds
# Firmware Source: AgustinLorenzo/openwrt
# ==============================================================================

set -e  # Exit immediately if a command exits with a non-zero status

# ==============================================================================
# CONFIGURATION & DEFAULTS
# ==============================================================================

# Directory definitions
BASE_DIR="$(pwd)"
WORK_DIR="${BASE_DIR}/workdir"
BUILD_DIR="${WORK_DIR}/openwrt"
CUSTOM_FILES_DIR="${WORK_DIR}/custom_files"
FANTASTIC_PACKAGES_DIR="${BUILD_DIR}/package/fantastic_packages"

# Repository URLs
REPO_FIRMWARE="https://github.com/AgustinLorenzo/openwrt.git"
BRANCH_FIRMWARE="main_nss"
REPO_CUSTOM="https://github.com/jkool702/openwrt-custom-builds.git"
REPO_FANTASTIC="https://github.com/fantastic-packages/packages.git"

# Tmpfs Settings
RAM_THRESHOLD_GB=60
TMPFS_SIZE="52g"

# Build Settings (Defaults)
MAKE_JOBS=""
VERBOSE_BUILD=false
RUN_MENUCONFIG=false 

# ==============================================================================
# VISUAL HELPER FUNCTIONS
# ==============================================================================

log() {
    echo -e "\n\033[1;34m[BUILD INFO] $1\033[0m"
}

warn() {
    echo -e "\n\033[1;33m[BUILD WARN] $1\033[0m"
}

error() {
    echo -e "\n\033[1;31m[BUILD ERROR] $1\033[0m"
    exit 1
}

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# ==============================================================================
# CORE FUNCTIONS
# ==============================================================================

check_debian() {
    log "Checking OS..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "debian" && "$ID_LIKE" != "debian" && "$ID" != "ubuntu" ]]; then
            error "This script is intended for Debian/Ubuntu systems. Detected: $ID"
        fi
    else
        error "Cannot detect OS. /etc/os-release missing."
    fi
}

install_dependencies() {
    log "Installing/Checking dependencies and ccache..."
    
    local SUDO=""
    if [ "$EUID" -ne 0 ]; then SUDO="sudo"; fi

    $SUDO apt-get update
    $SUDO apt-get install -y build-essential clang flex bison g++ gawk \
        gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
        python3-setuptools rsync swig unzip zlib1g-dev file wget \
        python3 python3-dev python3-pip libpython3-dev curl libelf-dev \
        xsltproc libxml-parser-perl patch diffutils findutils quilt zstd \
        libprotobuf-c1 libprotobuf-c-dev protobuf-c-compiler ccache
}

setup_tmpfs() {
    log "Checking memory for Tmpfs..."
    
    local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_gb=$((total_mem_kb / 1024 / 1024))

    log "Total Memory detected: ${total_mem_gb} GB"

    if [ "$total_mem_gb" -ge "$RAM_THRESHOLD_GB" ]; then
        if mount | grep -q "${WORK_DIR}"; then
            log "Tmpfs already mounted at ${WORK_DIR}."
        else
            log "Memory >= ${RAM_THRESHOLD_GB}GB. Mounting ${TMPFS_SIZE} tmpfs to ${WORK_DIR}..."
            mkdir -p "${WORK_DIR}"
            
            local SUDO=""
            if [ "$EUID" -ne 0 ]; then SUDO="sudo"; fi
            
            $SUDO mount -t tmpfs -o size=${TMPFS_SIZE} tmpfs "${WORK_DIR}"
            $SUDO chown "$(id -u):$(id -g)" "${WORK_DIR}"
        fi
    else
        log "Memory < ${RAM_THRESHOLD_GB}GB. Skipping Tmpfs, building on disk."
        mkdir -p "${WORK_DIR}"
    fi
}

configure_ccache() {
    log "Configuring ccache..."
    mkdir -p "${HOME}/.ccache"
    export CCACHE_DIR="${HOME}/.ccache"
    if ! command -v ccache &> /dev/null; then
        error "ccache not found despite installation attempt."
    fi
}

manage_git() {
    local repo_url=$1
    local target_dir=$2
    local branch=$3
    local prompt_update=$4
    local target_branch="${branch:-main}"
    
    local do_update=true

    if [ -d "${target_dir}/.git" ]; then
        if [ "$prompt_update" = true ]; then
            read -p "Repo at ${target_dir} exists. Update it? [y/N]: " update_choice
            if [[ ! "$update_choice" =~ ^[Yy]$ ]]; then
                do_update=false
            fi
        fi

        if [ "$do_update" = true ]; then
            log "Updating existing repo at ${target_dir}..."
            cd "${target_dir}"
            log "Fetching origin/${target_branch}..."
            git fetch origin "${target_branch}:refs/remotes/origin/${target_branch}" --depth 1 || {
                warn "Fetch specific branch failed, trying standard fetch..."
                git fetch origin
            }
            git reset --hard "origin/${target_branch}"
        else
            log "Skipping update for ${target_dir}."
        fi
    elif [ -d "${target_dir}" ]; then
        # Directory exists but is NOT a git repo
        error "Directory '${target_dir}' exists but is not a git repository. Personalized build detected/Invalid state. Please check documentation."
    else
        log "Cloning ${repo_url} to ${target_dir}..."
        git clone --depth 1 --branch "${target_branch}" --single-branch --recurse-submodules \
            "${repo_url}" "${target_dir}"
    fi
}

# ==============================================================================
# INTERACTIVE SETUP & FILE PREPARATION
# ==============================================================================

interactive_setup() {
    log "Starting Interactive Configuration..."
    
    # 1. CPU Threads
    local cpu_threads=$(nproc)
    echo "Detected CPU Threads: $cpu_threads"
    echo "Select number of jobs for make:"
    echo "1) All threads + 2 IO ($((cpu_threads + 2)))"
    echo "2) 3/4 Threads ($((cpu_threads * 3 / 4)))"
    echo "3) 1/2 Threads ($((cpu_threads / 2)))"
    echo "4) Single Thread (1)"
    
    read -p "Enter choice [1-4]: " job_choice
    case $job_choice in
        1) MAKE_JOBS=$((cpu_threads + 2)) ;;
        2) MAKE_JOBS=$((cpu_threads * 3 / 4)) ;;
        3) MAKE_JOBS=$((cpu_threads / 2)) ;;
        4) MAKE_JOBS=1 ;;
        *) MAKE_JOBS=$((cpu_threads + 2)); echo "Invalid choice, defaulting to max." ;;
    esac

    # 2. Verbosity
    read -p "Enable verbose output (V=s)? [y/N]: " verbose_choice
    if [[ "$verbose_choice" =~ ^[Yy]$ ]]; then
        VERBOSE_BUILD=true
        if [ "$MAKE_JOBS" -gt 1 ]; then
            warn "You have selected Multithreaded ($MAKE_JOBS jobs) AND Verbose output."
            echo "The logs may be interleaved and difficult to read in case of error."
            echo "Press ENTER to continue or Ctrl+C to abort."
            read
        fi
    else
        VERBOSE_BUILD=false
    fi

    # 3. Prepare Custom Files (Config/Scripts)
    # First, ensure we have the reference repo
    log "Checking Custom Files Repository..."
    manage_git "$REPO_CUSTOM" "$CUSTOM_FILES_DIR" "main-NSS" true

    local local_files_path="${BASE_DIR}/files"
    local ref_files_path="${CUSTOM_FILES_DIR}/WRX36/bin/extra/files"

    # Populate local files if empty
    if [ ! -d "$local_files_path" ] || [ -z "$(ls -A "$local_files_path")" ]; then
        log "Populating '${local_files_path}' from reference repo..."
        mkdir -p "$local_files_path"
        if [ -d "$ref_files_path" ]; then
            cp -r "$ref_files_path/." "$local_files_path/"
            # 1. REMOVE lib/modules from the LOCAL copy immediately
            if [ -d "$local_files_path/lib/modules" ]; then
                log "Removing 'lib/modules' from local files to prevent boot issues..."
                rm -rf "$local_files_path/lib/modules"
            fi
        else
            warn "Reference files not found at $ref_files_path."
        fi
    fi

    # Prompt for Review
    echo -e "\n\033[1;33m[USER ACTION REQUIRED]\033[0m"
    read -p "Do you want to pause to review/edit files in '${local_files_path}'? [y/N]: " review_files
    if [[ "$review_files" =~ ^[Yy]$ ]]; then
        echo -e "\n\033[1;32mScript PAUSED.\033[0m"
        echo "You can now edit '${local_files_path}'."
        echo "Note: 'lib/modules' has already been excluded."
        echo "If you need more time, stop the script (Ctrl+C) and run it again later."
        echo -e "Type \033[1;37mready\033[0m and press Enter to continue."
        while true; do
            read -p "> " input_str
            if [[ "$input_str" == "ready" ]]; then break; fi
        done
    fi

    # 4. Prepare Custom Packages
    local local_pkgs_path="${BASE_DIR}/packages"
    if [ ! -d "$local_pkgs_path" ]; then
        log "Creating '${local_pkgs_path}' directory..."
        mkdir -p "$local_pkgs_path"
    fi

    # Prompt for Packages Review
    read -p "Do you want to pause to add/edit custom packages in '${local_pkgs_path}'? [y/N]: " review_pkgs
    if [[ "$review_pkgs" =~ ^[Yy]$ ]]; then
        echo -e "\n\033[1;32mScript PAUSED.\033[0m"
        echo "Add directories containing Makefiles to '${local_pkgs_path}'."
        echo -e "Type \033[1;37mready\033[0m and press Enter to continue."
        while true; do
            read -p "> " input_str
            if [[ "$input_str" == "ready" ]]; then break; fi
        done
    fi

    # 5. Update Firmware Repositories
    log "Checking Firmware Repositories..."
    manage_git "$REPO_FIRMWARE" "$BUILD_DIR" "$BRANCH_FIRMWARE" true
    # Fantastic packages is inside build dir, so managed after firmware clone
}

# ==============================================================================
# BUILD HELPERS
# ==============================================================================

safe_make() {
    local target_desc="$1"
    shift
    local make_args=("$@")
    
    local log_file="${BASE_DIR}/build_${target_desc// /_}.log"
    local err_file="${BASE_DIR}/build_${target_desc// /_}_errors.log"
    
    log "Running Make: ${target_desc} (-j${MAKE_JOBS})..."
    echo "Full log: $log_file"
    
    local status=0
    local cmd="make -j${MAKE_JOBS} ${make_args[*]}"
    
    if [ "$VERBOSE_BUILD" = true ]; then
        cmd="$cmd V=s"
        ( set -o pipefail; eval "$cmd" 2>&1 | tee "$log_file" ) || status=$?
    else
        eval "$cmd" > "$log_file" 2>&1 &
        local pid=$!
        spinner $pid
        wait $pid || status=$?
    fi
    
    if [ -f "$log_file" ]; then
        grep -iE ": error:|: fatal error:|: undefined reference to|command not found|failed|cannot|unable to|missing" "$log_file" | tail -n 200 > "$err_file" || true
    fi

    if [ $status -ne 0 ]; then
        echo -e "\n\033[1;31m[FAIL] Step '${target_desc}' failed! (Exit Code: $status)\033[0m"
        if [ -s "$err_file" ]; then
            echo -e "\n\033[1;33m--- DETECTED ERRORS (Last 200 lines) ---\033[0m"
            cat "$err_file"
            echo -e "\033[1;33m----------------------------------------\033[0m"
        else
            echo "No specific error patterns matched. Checking tail of full log:"
            tail -n 200 "$log_file"
        fi
        echo -e "\n\033[1;31m[FAIL] Step '${target_desc}' failed! (Exit Code: $status)\033[0m"
        echo -e "\n\033[1;37mTo view the complete log, run:\033[0m"
        echo -e "less +G \"$log_file\""
        echo -e "\n\033[1;30mTips for less:\033[0m"
        echo -e "  Type \033[1;37m/Error 1\033[0m to search for errors."
        echo -e "  Press \033[1;37mn\033[0m (next) or \033[1;37mN\033[0m (prev). \033[1;37mq\033[0m to quit."
        exit $status
    else
        echo -e "\033[1;32m[SUCCESS] Step '${target_desc}' completed successfully.\033[0m"
    fi
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

# 1. System & Dependency Checks
check_debian
install_dependencies

# 2. Filesystem Setup
setup_tmpfs
configure_ccache

# 3. Interactive Setup (Prompts, Repo Updates, File Prep)
interactive_setup

# 4. Additional Sources (Inside Firmware Dir)
# Fantastic packages (using snapshot branch)
manage_git "$REPO_FANTASTIC" "$FANTASTIC_PACKAGES_DIR" "snapshot" true

# 5. Prepare Build Environment
cd "${BUILD_DIR}"

log "Updating feeds..."
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/feeds install -a

# 5.1 Inject User Content (Files & Packages)
# ------------------------------------------
# Files: Clean build_dir/files, then Copy base_dir/files -> build_dir/files
log "Injecting Custom Files into Firmware..."
if [ -d "${BUILD_DIR}/files" ]; then
    log "Cleaning existing firmware files directory..."
    rm -rf "${BUILD_DIR}/files"
fi

local_files_path="${BASE_DIR}/files"
if [ -d "$local_files_path" ] && [ -n "$(ls -A "$local_files_path")" ]; then
    log "Copying user files from '${local_files_path}'..."
    mkdir -p "${BUILD_DIR}/files"
    cp -r "$local_files_path/." "${BUILD_DIR}/files/"
    
    # SAFETY: Double check removal of lib/modules inside the firmware build tree
    if [ -d "${BUILD_DIR}/files/lib/modules" ]; then
        warn "Removing 'lib/modules' from firmware build tree (Safety Check)."
        rm -rf "${BUILD_DIR}/files/lib/modules"
    fi
else
    log "No custom files to inject."
fi

# Packages: Inject base_dir/packages -> build_dir/package/custom
log "Injecting Custom Packages..."
local_pkgs_path="${BASE_DIR}/packages"
if [ -d "$local_pkgs_path" ] && [ -n "$(ls -A "$local_pkgs_path")" ]; then
    mkdir -p "${BUILD_DIR}/package/custom"
    cp -r "$local_pkgs_path/." "${BUILD_DIR}/package/custom/"
fi

# 5.2 Fix Recursive Dependencies
log "Checking for recursive dependency in tar package..."
TAR_MAKEFILE=$(find package -name Makefile | xargs grep -l "menuconfig PACKAGE_tar" | head -n 1)
if [ -n "$TAR_MAKEFILE" ]; then
    if grep -q "depends on !(PACKAGE_TAR_XZ)" "$TAR_MAKEFILE"; then
        log "Patching recursive dependency in $TAR_MAKEFILE..."
        sed -i '/depends on !(PACKAGE_TAR_XZ)/d' "$TAR_MAKEFILE"
    fi
fi

# 5.3 Fix Aria2 build errors with LTO/MOLD
log "Patching Aria2 to disable LTO/Mold (Insertion Method)..."
ARIA2_MAKEFILE=$(find package -name Makefile | grep "aria2/Makefile" | head -n 1)
if [ -n "$ARIA2_MAKEFILE" ]; then
    if ! grep -q "PKG_BUILD_FLAGS:=no-lto" "$ARIA2_MAKEFILE"; then
        sed -i '/include $(TOPDIR)\/rules.mk/a PKG_BUILD_FLAGS:=no-lto\nTARGET_LDFLAGS += -fuse-ld=bfd' "$ARIA2_MAKEFILE"
        log "Inserted PKG_BUILD_FLAGS:=no-lto and BFD linker enforcement."
    fi
    make "${ARIA2_MAKEFILE%/Makefile}/clean"
    find build_dir -name "aria2-*" -type d -exec rm -rf {} + 2>/dev/null || true
fi

# 6. Apply Customizations & Configs
log "Applying custom configurations..."
PREV_CONFIG="${CUSTOM_FILES_DIR}/WRX36/bin/extra/configs/.config"
PREV_DIFF="${CUSTOM_FILES_DIR}/WRX36/bin/extra/configs/.config.diff"

if [ -f "${PREV_DIFF}" ]; then
    log "Applying .config.diff..."
    cp "${PREV_DIFF}" .config
    make defconfig
elif [ -f "${PREV_CONFIG}" ]; then
    log "Applying full .config..."
    cp "${PREV_CONFIG}" .config
else
    log "No previous config found. Using default."
    make defconfig
fi

# 7. Apply Config Modifications
log "Injecting Custom Packages and CCACHE..."

add_package() {
    local pkg=$1
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
}

sed -i '/CONFIG_CCACHE/d' .config
echo "CONFIG_CCACHE=y" >> .config

if command -v ccache &> /dev/null; then
    mkdir -p staging_dir/host/bin
    ln -sf "$(command -v ccache)" staging_dir/host/bin/ccache
fi

add_package "aria2"
add_package "luci-app-aria2"
add_package "ariang"
add_package "luci-app-ariang"
add_package "btop"
add_package "htop"
add_package "nano"
add_package "e2fsprogs"
add_package "dosfstools"
add_package "f2fs-tools"
add_package "irqbalance"

# Disable Vim
sed -i '/CONFIG_PACKAGE_vim/d' .config
sed -i '/CONFIG_PACKAGE_vim-full/d' .config
sed -i '/CONFIG_PACKAGE_vim-tiny/d' .config
echo "# CONFIG_PACKAGE_vim is not set" >> .config
echo "# CONFIG_PACKAGE_vim-full is not set" >> .config
echo "# CONFIG_PACKAGE_vim-tiny is not set" >> .config

# Disable sstp-client
sed -i '/CONFIG_PACKAGE_luci-proto-sstp/d' .config
sed -i '/CONFIG_PACKAGE_sstp-client/d' .config
echo "# CONFIG_PACKAGE_luci-proto-sstp is not set" >> .config
echo "# CONFIG_PACKAGE_sstp-client is not set" >> .config

log "Syncing configuration..."
make defconfig

# 8. Menuconfig (Optional)
if [ "$RUN_MENUCONFIG" = true ]; then
    log "Entering Menuconfig..."
    make menuconfig
    ./scripts/diffconfig.sh > .config.diff
fi

# 9. Unattended Code Fixes
log "Applying unattended code fixes..."
if [ -f "include/cmake.mk" ] && ! grep -q "CMAKE_POLICY_VERSION_MINIMUM=3.5" include/cmake.mk; then
    sed -i '/^cmake_bool[[:space:]]*=/a CMAKE_OPTIONS += -DCMAKE_POLICY_VERSION_MINIMUM=3.5' include/cmake.mk
fi

# 9.1 Fix: Patch ksmbd
KSMBD_INIT=$(find package -name "ksmbd.init" 2>/dev/null | head -n 1)
if [ -n "$KSMBD_INIT" ]; then
    if ! grep -q "REMOVE SYSTEM SHARES" "$KSMBD_INIT"; then
        cat << 'EOF' > ksmbd_fix.txt
    # --- FIX: REMOVE SYSTEM SHARES ---
    # Ensure the config file exists before editing
    if [ -f /var/etc/ksmbd/ksmbd.conf ]; then
        # Delete the [ubi0_2] block and lines following it
        sed -i '/\[ubi0_2\]/,/^$/d' /var/etc/ksmbd/ksmbd.conf
        # Delete the [ubiblock0_1] block and lines following it
        sed -i '/\[ubiblock0_1\]/,/^$/d' /var/etc/ksmbd/ksmbd.conf
    fi
    # ---------------------------------
EOF
        awk 'NR==FNR{fix[n++]=$0; next} /procd_open_instance/{for(i=0;i<n;i++) print fix[i]} 1' ksmbd_fix.txt "$KSMBD_INIT" > "$KSMBD_INIT.tmp" && mv "$KSMBD_INIT.tmp" "$KSMBD_INIT"
        rm ksmbd_fix.txt
        log "Applied ksmbd patch to $KSMBD_INIT"
    fi
fi

# 10. Disable Global LTO/MOLD
log "Disabling Global LTO and Mold..."
sed -i '/CONFIG_USE_MOLD/d' .config
echo "# CONFIG_USE_MOLD is not set" >> .config
sed -i '/CONFIG_USE_LTO/d' .config
echo "# CONFIG_USE_LTO is not set" >> .config
make defconfig

# 11. Clean Aria2
make package/aria2/clean || true
find build_dir -name "aria2-*" -type d -exec rm -rf {} + 2>/dev/null || true

# 12. Download Sources
safe_make "Download Sources" download

# 13. Kernel Tweaks
log "Pre-preparing kernel..."
safe_make "Prepare Kernel Config" prepare_kernel_conf

KERNEL_BUILD_DIR=$(find build_dir/target* -maxdepth 2 -name "linux-*" -type d | head -n 1)
if [ -n "$KERNEL_BUILD_DIR" ]; then
    ARM64_MAKEFILE="${KERNEL_BUILD_DIR}/arch/arm64/Makefile"
    if [ -f "$ARM64_MAKEFILE" ]; then
        sed -i 's/^asm-arch := .*/asm-arch := armv8-a+crc+crypto+rdma/' "$ARM64_MAKEFILE"
        if ! grep -q "cortex-a53+crc+crypto+rdma" "$ARM64_MAKEFILE"; then
             echo "KBUILD_AFLAGS += -Wa,-mcpu=cortex-a53+crc+crypto+rdma" >> "$ARM64_MAKEFILE"
             echo "KBUILD_CFLAGS += -Wa,-mcpu=cortex-a53+crc+crypto+rdma" >> "$ARM64_MAKEFILE"
        fi
    fi
fi

# 14. Final Build
log "Starting Final Build..."
safe_make "Prepare Build" prepare
safe_make "Final Firmware Build"

log "Build Complete. Images should be in ${BUILD_DIR}/bin/targets/"
