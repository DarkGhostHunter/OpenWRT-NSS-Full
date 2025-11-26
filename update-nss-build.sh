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

# Build Settings (Populated by prompts)
MAKE_JOBS=""
VERBOSE_BUILD=false
RUN_MENUCONFIG=false # Set to true to force menuconfig in unattended mode, or use prompts
UPDATE_CUSTOM_FILES=true
UPDATE_FIRMWARE=true
UPDATE_FANTASTIC_PACKAGES=true

# ==============================================================================
# VISUAL HELPER FUNCTIONS
# ==============================================================================

log() {
    # Changed to BLUE as requested
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

configure_build_settings() {
    log "User Configuration"
    
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

    # 3. Repository Management
    log "Checking Repositories..."

    # Check Custom Files Repo
    if [ -d "$CUSTOM_FILES_DIR" ]; then
        # If directory exists, check if it is a git repo
        if [ -d "$CUSTOM_FILES_DIR/.git" ]; then
            read -p "Custom Files Repo detected at ${CUSTOM_FILES_DIR}. Update it? [y/N]: " update_custom
            if [[ "$update_custom" =~ ^[Yy]$ ]]; then
                UPDATE_CUSTOM_FILES=true
            else
                UPDATE_CUSTOM_FILES=false
            fi
        else
            # Directory exists but NOT a git repo -> Personalized Build Detected
            echo -e "\n\033[1;31m[ERROR] Directory '${CUSTOM_FILES_DIR}' exists but is not a git repository.\033[0m"
            echo -e "\033[1;33mPERSONALIZED BUILD DETECTED.\033[0m"
            echo "This script is designed for automated Git-based builds."
            echo "Please build manually or refer to the OpenWRT official documentation:"
            echo "https://openwrt.org/docs/guide-developer/build-system/use-buildsystem"
            exit 1
        fi
    else
        # Doesn't exist, will be cloned automatically
        UPDATE_CUSTOM_FILES=true 
    fi

    # Check Firmware Repo
    if [ -d "$BUILD_DIR" ]; then
        if [ -d "$BUILD_DIR/.git" ]; then
            read -p "Firmware Repo detected at ${BUILD_DIR}. Update it? [y/N]: " update_fw
            if [[ "$update_fw" =~ ^[Yy]$ ]]; then
                UPDATE_FIRMWARE=true
            else
                UPDATE_FIRMWARE=false
            fi
        else
            echo -e "\n\033[1;31m[ERROR] Directory '${BUILD_DIR}' exists but is not a git repository.\033[0m"
            echo -e "\033[1;33mPERSONALIZED BUILD DETECTED.\033[0m"
            echo "This script is designed for automated Git-based builds."
            echo "Please build manually or refer to the OpenWRT official documentation:"
            echo "https://openwrt.org/docs/guide-developer/build-system/use-buildsystem"
            exit 1
        fi
    else
        UPDATE_FIRMWARE=true
    fi

    # Check Fantastic Packages Repo (openwrt/packages extra)
    if [ -d "$FANTASTIC_PACKAGES_DIR" ]; then
        if [ -d "$FANTASTIC_PACKAGES_DIR/.git" ]; then
            read -p "Fantastic Packages Repo detected at ${FANTASTIC_PACKAGES_DIR}. Update it? [y/N]: " update_pkg
            if [[ "$update_pkg" =~ ^[Yy]$ ]]; then
                UPDATE_FANTASTIC_PACKAGES=true
            else
                UPDATE_FANTASTIC_PACKAGES=false
            fi
        else
            echo -e "\n\033[1;31m[ERROR] Directory '${FANTASTIC_PACKAGES_DIR}' exists but is not a git repository.\033[0m"
            echo -e "\033[1;33mPERSONALIZED BUILD DETECTED.\033[0m"
            echo "This script is designed for automated Git-based builds."
            echo "Please build manually or refer to the OpenWRT official documentation:"
            echo "https://openwrt.org/docs/guide-developer/build-system/use-buildsystem"
            exit 1
        fi
    else
        # Does not exist (or parent doesn't exist yet), will be cloned automatically
        UPDATE_FANTASTIC_PACKAGES=true
    fi
}

manage_custom_files() {
    local local_files_path="${BASE_DIR}/files"
    # Path to jkool702's files in the cloned repo
    local ref_files_path="${CUSTOM_FILES_DIR}/WRX36/bin/extra/files"

    log "Managing Custom Configuration Files..."

    # 1. Populate if empty/missing
    if [ ! -d "$local_files_path" ] || [ -z "$(ls -A "$local_files_path")" ]; then
        if [ -d "$ref_files_path" ]; then
            log "Local files folder empty or missing. Copying defaults from jkool702..."
            mkdir -p "$local_files_path"
            # Use cp -rT to copy contents, including hidden files
            cp -r "$ref_files_path/." "$local_files_path/"
        else
            warn "Reference files not found at $ref_files_path. Starting with empty files directory."
            mkdir -p "$local_files_path"
        fi
    else
        log "Local files directory exists and is not empty. Keeping existing files."
    fi

    # 2. Prompt for editing
    echo -e "\n\033[1;33m[USER ACTION REQUIRED]\033[0m"
    read -p "Do you want to pause to edit/review custom files in '${local_files_path}'? [y/N]: " edit_choice
    if [[ "$edit_choice" =~ ^[Yy]$ ]]; then
        echo -e "\n\033[1;32mScript PAUSED.\033[0m"
        echo "You can now edit the files in: ${local_files_path}"
        echo "Tip: Scripts in 'etc/uci-defaults/' run once on first boot to set configuration."
        echo "If you need significant time, you can press Ctrl+C to stop, finish editing, and restart the script."
        echo -e "Type \033[1;37mready\033[0m and press Enter when you are done."
        
        while true; do
            read -p "> " input_str
            if [[ "$input_str" == "ready" ]]; then
                break
            fi
            echo "Type 'ready' to continue."
        done
        log "Resuming build..."
    fi

    # 3. Inject into build
    # The build system looks for a directory named 'files' in the root of the build directory
    if [ -d "$local_files_path" ] && [ -n "$(ls -A "$local_files_path")" ]; then
        log "Injecting custom files into build directory..."
        # Use cp -r to copy the directory contents into the target
        # We copy to ${BUILD_DIR}/files because that's where OpenWRT looks for overlays
        mkdir -p "${BUILD_DIR}/files"
        cp -r "$local_files_path/." "${BUILD_DIR}/files/"
    fi
}

manage_git() {
    local repo_url=$1
    local target_dir=$2
    local branch=$3
    local should_update=$4
    local target_branch="${branch:-main}"

    if [ -d "${target_dir}/.git" ]; then
        if [ "$should_update" = true ]; then
            log "Updating existing repo at ${target_dir}..."
            cd "${target_dir}"
            
            # Fix: Fetch the specific branch mapping explicitly.
            # This solves "unknown revision" if the repo was previously cloned with --single-branch
            log "Fetching origin/${target_branch}..."
            git fetch origin "${target_branch}:refs/remotes/origin/${target_branch}" --depth 1 || {
                warn "Fetch specific branch failed, trying standard fetch..."
                git fetch origin
            }
            
            git reset --hard "origin/${target_branch}"
        else
            log "Skipping update for ${target_dir} (User Request)."
        fi
    else
        log "Cloning ${repo_url} to ${target_dir}..."
        git clone --depth 1 --branch "${target_branch}" --single-branch --recurse-submodules \
            "${repo_url}" "${target_dir}"
    fi
}

safe_make() {
    local target_desc="$1"
    shift
    local make_args=("$@")
    
    # Define log files in BASE_DIR (not WORK_DIR)
    local log_file="${BASE_DIR}/build_${target_desc// /_}.log"
    local err_file="${BASE_DIR}/build_${target_desc// /_}_errors.log"
    
    log "Running Make: ${target_desc} (-j${MAKE_JOBS})..."
    echo "Full log: $log_file"
    
    local status=0
    
    # Construct the command
    local cmd="make -j${MAKE_JOBS} ${make_args[*]}"
    if [ "$VERBOSE_BUILD" = true ]; then
        # Add V=s if verbose requested
        cmd="$cmd V=s"
        # Verbose: Pipe to tee to show on screen AND write to log_file
        # We use a subshell with pipefail to capture the make exit code, not tee's
        # Uses || status=$? to catch failure code without triggering set -e exit
        (
            set -o pipefail
            eval "$cmd" 2>&1 | tee "$log_file"
        ) || status=$?
    else
        # Non-Verbose: Redirect stdout AND stderr to log_file
        eval "$cmd" > "$log_file" 2>&1 &
        local pid=$!
        spinner $pid
        # Wait returns the exit code of the process. 
        # Uses || status=$? to catch failure code without triggering set -e exit
        wait $pid || status=$?
    fi
    
    # Always generate the filtered error file from the main log
    if [ -f "$log_file" ]; then
        # Filter logic: specific compiler errors, generic failure keywords, and "missing"
        # Added "missing" to regex and increased tail to 200
        grep -iE ": error:|: fatal error:|: undefined reference to|command not found|failed|cannot|unable to|missing" "$log_file" | tail -n 200 > "$err_file" || true
    fi

    if [ $status -ne 0 ]; then
        # Output failing step in RED (Top)
        echo -e "\n\033[1;31m[FAIL] Step '${target_desc}' failed! (Exit Code: $status)\033[0m"
        
        if [ -s "$err_file" ]; then
            echo -e "\n\033[1;33m--- DETECTED ERRORS (Last 200 lines) ---\033[0m"
            cat "$err_file"
            echo -e "\033[1;33m----------------------------------------\033[0m"
        else
            echo "No specific error patterns matched in filter. Checking tail of full log:"
            tail -n 200 "$log_file"
        fi

        # Output failing step in RED (Repeated at Bottom)
        echo -e "\n\033[1;31m[FAIL] Step '${target_desc}' failed! (Exit Code: $status)\033[0m"

        # Suggest viewing the full log with tips
        echo -e "\n\033[1;37mTo view the complete log, run:\033[0m"
        echo -e "less +G \"$log_file\""
        echo -e "\n\033[1;30mTips for less:\033[0m"
        echo -e "  Type \033[1;37m/Error 1\033[0m to search for common make errors."
        echo -e "  Press \033[1;37mn\033[0m (next) or \033[1;37mN\033[0m (previous) to navigate matches."
        echo -e "  Press \033[1;37mq\033[0m to quit."
        
        exit $status
    else
        # Success message in GREEN
        echo -e "\033[1;32m[SUCCESS] Step '${target_desc}' completed successfully.\033[0m"
    fi
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

# 1. System Checks
check_debian
install_dependencies

# 2. Filesystem Setup
setup_tmpfs
configure_ccache

# 3. Config Prompts (Moved after tmpfs setup to detect directories correctly)
configure_build_settings

# 4. Fetch Sources
# Fix: Correct branch for Custom Files is main-NSS per user instruction
manage_git "$REPO_CUSTOM" "$CUSTOM_FILES_DIR" "main-NSS" "$UPDATE_CUSTOM_FILES"
manage_git "$REPO_FIRMWARE" "$BUILD_DIR" "$BRANCH_FIRMWARE" "$UPDATE_FIRMWARE"
# Changed fantastic-packages to use 'snapshot' branch
manage_git "$REPO_FANTASTIC" "$FANTASTIC_PACKAGES_DIR" "snapshot" "$UPDATE_FANTASTIC_PACKAGES"

# 5. Prepare Build Environment
cd "${BUILD_DIR}"

log "Updating feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

log "Second feed install pass..."
./scripts/feeds install -a

# 5.1 Fix Recursive Dependency in Packages
# This MUST happen before 'make defconfig' or 'make menuconfig'
log "Checking for recursive dependency in tar package..."
# Find the tar package makefile (usually in feeds/packages/utils/tar/Makefile)
TAR_MAKEFILE=$(find package -name Makefile | xargs grep -l "menuconfig PACKAGE_tar" | head -n 1)

if [ -n "$TAR_MAKEFILE" ]; then
    log "Found tar makefile at: $TAR_MAKEFILE"
    # Remove the circular dependency line "depends on !(PACKAGE_TAR_XZ) || PACKAGE_xz-utils"
    # The logic is flawed because PACKAGE_TAR_XZ is a child of PACKAGE_tar
    if grep -q "depends on !(PACKAGE_TAR_XZ)" "$TAR_MAKEFILE"; then
        log "Patching recursive dependency in $TAR_MAKEFILE..."
        sed -i '/depends on !(PACKAGE_TAR_XZ)/d' "$TAR_MAKEFILE"
    else
        log "Tar makefile seems already patched or different version."
    fi
else
    warn "Could not locate tar package makefile. If build fails with recursive dependency, check feeds."
fi

# 5.2 Fix Aria2 build errors with LTO/MOLD
# Correct approach: Insert flags at the TOP of the Makefile so they are read before 'include package.mk'
log "Patching Aria2 to disable LTO/Mold (Insertion Method)..."
ARIA2_MAKEFILE=$(find package -name Makefile | grep "aria2/Makefile" | head -n 1)

if [ -n "$ARIA2_MAKEFILE" ]; then
    log "Found Aria2 makefile at: $ARIA2_MAKEFILE"
    
    # We must insert PKG_BUILD_FLAGS:=no-lto near the top, after the first include
    # This ensures OpenWRT sees it before generating build targets.
    # We also explicitly force BFD linker in TARGET_LDFLAGS.
    if ! grep -q "PKG_BUILD_FLAGS:=no-lto" "$ARIA2_MAKEFILE"; then
        sed -i '/include $(TOPDIR)\/rules.mk/a PKG_BUILD_FLAGS:=no-lto\nTARGET_LDFLAGS += -fuse-ld=bfd' "$ARIA2_MAKEFILE"
        log "Inserted PKG_BUILD_FLAGS:=no-lto and BFD linker enforcement."
    else
        log "Aria2 Makefile already contains no-lto flag."
    fi

    # CRITICAL: Clean Aria2 to ensure new flags are picked up!
    log "Cleaning Aria2 package to enforce configuration changes..."
    make "${ARIA2_MAKEFILE%/Makefile}/clean"
    
    # NEW: Deep clean by removing the build directory manually
    # This addresses the persistence of the 'undefined symbol' error by forcing a fresh compile.
    log "Deep cleaning Aria2 build artifacts..."
    find build_dir -name "aria2-*" -type d -exec rm -rf {} + 2>/dev/null || true
else
    warn "Could not locate Aria2 makefile. Build might fail if LTO is enabled."
fi

# 6. Apply Customizations & Configs
log "Applying custom configurations (files & settings)..."

# REPLACED old copy logic with new interactive function
# manage_custom_files handles copying defaults, pausing for edits, and injecting
manage_custom_files

# We still need configs, so we adapt the old logic for config files ONLY (not files dir)
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

# 7. Apply Config Modifications (Packages & CCACHE)
log "Injecting Custom Packages and CCACHE..."

# Helper to add package
add_package() {
    local pkg=$1
    echo "CONFIG_PACKAGE_${pkg}=y" >> .config
}

sed -i '/CONFIG_CCACHE/d' .config
echo "CONFIG_CCACHE=y" >> .config

# Fix: Manually link ccache to staging_dir to prevent ninja/build errors
# The build system expects it in staging_dir/host/bin
if command -v ccache &> /dev/null; then
    mkdir -p staging_dir/host/bin
    ln -sf "$(command -v ccache)" staging_dir/host/bin/ccache
    log "Linked system ccache to staging_dir/host/bin/ccache"
fi

# Add requested packages
add_package "aria2"           # Core download utility (backend)
add_package "luci-app-aria2"  # LuCI configuration interface for Aria2
add_package "ariang"          # Web frontend for Aria2
add_package "luci-app-ariang" # LuCI integration for AriaNg
add_package "btop"
add_package "htop" # Fallback/Alternative
add_package "nano" # Basic editor
add_package "e2fsprogs" # fsck for ext2/3/4
add_package "dosfstools" # fsck for FAT
add_package "f2fs-tools" # fsck for F2FS

# Disable Vim to prevent build errors due to environment changes
log "Disabling Vim to avoid configuration errors..."
sed -i '/CONFIG_PACKAGE_vim/d' .config
sed -i '/CONFIG_PACKAGE_vim-full/d' .config
sed -i '/CONFIG_PACKAGE_vim-tiny/d' .config
echo "# CONFIG_PACKAGE_vim is not set" >> .config
echo "# CONFIG_PACKAGE_vim-full is not set" >> .config
echo "# CONFIG_PACKAGE_vim-tiny is not set" >> .config

# Disable sstp-client and its dependents to resolve file conflict with ppp
log "Disabling sstp-client and dependents to resolve file conflict with ppp..."
# We must disable the protocol handler (luci-proto-sstp) because it selects sstp-client
sed -i '/CONFIG_PACKAGE_luci-proto-sstp/d' .config
sed -i '/CONFIG_PACKAGE_sstp-client/d' .config
echo "# CONFIG_PACKAGE_luci-proto-sstp is not set" >> .config
echo "# CONFIG_PACKAGE_sstp-client is not set" >> .config

# Sync configuration to avoid "out of sync" warnings
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

# 9.1 Fix: Patch ksmbd to remove system shares
log "Patching ksmbd init script to remove internal system shares..."
KSMBD_INIT=$(find package -name "ksmbd.init" 2>/dev/null | head -n 1)

if [ -n "$KSMBD_INIT" ]; then
    if grep -q "REMOVE SYSTEM SHARES" "$KSMBD_INIT"; then
        log "ksmbd.init already patched."
    else
        # Create patch content in a temp file
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
        
        # Insert using awk before procd_open_instance
        awk 'NR==FNR{fix[n++]=$0; next} /procd_open_instance/{for(i=0;i<n;i++) print fix[i]} 1' ksmbd_fix.txt "$KSMBD_INIT" > "$KSMBD_INIT.tmp" && mv "$KSMBD_INIT.tmp" "$KSMBD_INIT"
        rm ksmbd_fix.txt
        log "Applied ksmbd patch to $KSMBD_INIT"
    fi
else
    warn "Could not find ksmbd.init to patch. System shares fix not applied."
fi

# 10. Disable LTO and MOLD Globally (Stability Fix)
# The user experienced persistent linker errors (ltrans/mold) with Aria2.
# Disabling these features globally is the most robust fix.
log "Disabling Global LTO and Mold support for build stability..."
sed -i '/CONFIG_USE_MOLD/d' .config
echo "# CONFIG_USE_MOLD is not set" >> .config
sed -i '/CONFIG_USE_LTO/d' .config
echo "# CONFIG_USE_LTO is not set" >> .config

# Force config update
make defconfig

# 11. Clean Aria2 (Remove old LTO artifacts)
# This addresses the user query: "Should be this fixed by removing Aria2 compiled artifacts?"
# YES. We must ensure no LTO objects remain.
log "Cleaning Aria2 to remove any stale LTO artifacts..."
# We use the package name 'aria2' which OpenWRT finds automatically
make package/aria2/clean || warn "Aria2 clean step returned non-zero (might not be built yet), continuing..."

# Also deep clean directory if it exists
find build_dir -name "aria2-*" -type d -exec rm -rf {} + 2>/dev/null || true

# 12. Download Sources
safe_make "Download Sources" download

# 13. Kernel Tweaks
log "Pre-preparing kernel..."
safe_make "Prepare Kernel Config" prepare_kernel_conf

KERNEL_BUILD_DIR=$(find build_dir/target* -maxdepth 2 -name "linux-*" -type d | head -n 1)

if [ -z "$KERNEL_BUILD_DIR" ]; then
    warn "Could not determine Kernel Build Dir. Skipping specific Kernel Makefile patches."
else
    log "Patching Kernel Makefile in $KERNEL_BUILD_DIR..."
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

# Re-run prepare
safe_make "Prepare Build" prepare

# Main Compile
# Removed IGNORE_ERRORS=1 and -k to ensure we fail fast and see the actual error.
safe_make "Final Firmware Build"

log "Build Complete. Images should be in ${BUILD_DIR}/bin/targets/"
