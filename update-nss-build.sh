#!/bin/bash
# =========================================================================
# OpenWRT NSS Build Script (Unattended Mode)
#
# LOGIC FLOW:
# 1. Define Reusable Helpers & Variables
# 2. Configuration Phase (Ask all questions now)
# 3. Execution Phase (Run without interruption)
# =========================================================================

# --- Safety Settings ---
set -e          # Exit immediately on error
set -o pipefail # Fail if any command in a pipe fails

# --- Global Variables ---
# Define the base directory as the current working directory
BASE_DIR="$(pwd)"

LOG_FILE=""
BUILD_SUCCESSFUL=false
CCACHE_DIR="$BASE_DIR/.ccache"
PACKAGE_CACHE_DIR="$BASE_DIR/package_cache"
FIRMWARE_DIR="$BASE_DIR/nss-base/bin/targets/qualcommax/ipq807x"
BUILD_DIR_PATH="$BASE_DIR/nss-base/build_dir"
TMPFS_MOUNTED=false

# Options imported from environment (if any)
prev_files_dir_path="${prev_files_dir_path:-}"
prev_diff_config_path="${prev_diff_config_path:-}"
prev_kernel_config_path="${prev_kernel_config_path:-}"
prev_full_config_path="${prev_full_config_path:-}"

# =========================================================================
# === 1. REUSABLE HELPER FUNCTIONS ===
# =========================================================================

prompt_user_input() {
    local message="$1"
    local timeout="$2"
    local default_choice="$3"
    local choice=""

    echo -n "$message (auto-$default_choice in ${timeout}s): " >&2

    if read -r -t "$timeout" choice; then
        echo "" >&2
    else
        echo "" >&2
        echo "Timeout reached, defaulting to ${default_choice^^}" >&2
        choice="$default_choice"
    fi
    echo "$choice"
}

generate_error_log() {
    local log_file="$1"
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        local error_log="${log_file%.txt}_errors.txt"
        {
            echo "=========================================="
            echo "OpenWRT Build - Errors and Warnings"
            echo "Date: $(date)"
            echo "=========================================="
        } > "$error_log"
        # shellcheck disable=SC2126 # grep | grep is clearer here than complex regex
        grep -n -iE "(error|command not found|fatal|failed|cannot|unable to)" "$log_file" | grep -vi "warning" >> "$error_log" 2>/dev/null || true
        echo "✓ Filtered log created: $error_log"
    fi
}

# --- Loading Animation Function ---
show_loading_animation() {
    local pid=$1
    local log_file=$2
    local delay=0.15
    local spinstr='|/-\'
    local temp

    # Hide cursor (if supported)
    tput civis 2>/dev/null || true

    echo "" # Start on new line

    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        local spinchar=${spinstr%"$temp"}
        local spinstr=$temp$spinchar

        # Get the last line of the log to show current activity
        # We cut it to 70 chars to prevent line wrapping messiness
        local current_task=$(tail -n 1 "$log_file" 2>/dev/null | tr -cd '[:print:]' | cut -c1-70)

        if [ -z "$current_task" ]; then current_task="Initializing..."; fi

        # \r moves cursor to start of line, \033[K clears the rest of the line
        printf "\r [%c] Building: %-70s" "$spinchar" "$current_task"

        sleep "$delay"
    done

    # Restore cursor
    tput cnorm 2>/dev/null || true
    echo "" # Final newline
}

clone_or_update_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local branch="$3"

    echo "Processing $target_dir..."
    if [ -d "$target_dir" ]; then
        if pushd "$target_dir" > /dev/null; then
            if [ -d ".git" ]; then
                git fetch origin
                git reset --hard origin/"$branch"
                git pull
            else
                echo "⚠️  Directory exists but is not a git repository."
            fi
            popd > /dev/null || return 1
        else
            echo "❌ ERROR: Failed to change directory to $target_dir"
            exit 1
        fi
    else
        git clone --single-branch --no-tags --recurse-submodules --depth 1 --branch "$branch" "$repo_url" "$target_dir"
    fi
}

find_latest_artifact_name() {
    local pattern="$1"
    local base_url="https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq807x"
    # shellcheck disable=SC2086 # Pattern needs to expand
    curl -sL "$base_url/" | grep -oE "href=\"(${pattern})\"" | sed -E 's/href="([^"]+)"/\1/' | head -n 1
}

download_prebuilt_artifact() {
    local pattern="$1"
    local expected_dir="$2"
    local base_url="https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq807x"
    local file_name="$pattern"

    if [[ "$pattern" == *"*"* ]]; then
        file_name=$(find_latest_artifact_name "${pattern}")
        [ -z "$file_name" ] && return 1
    fi

    if [ -d "$expected_dir" ] || [ -f "$file_name" ]; then
        echo "✓ $(basename "$file_name") present"
        return 0
    fi

    echo "Downloading $file_name..."
    if wget -q --show-progress "$base_url/$file_name" -O "$file_name"; then
        if [[ "$file_name" == *.tar.zst ]]; then
            tar --zstd -xf "$file_name"
            if [[ "$file_name" == llvm-bpf-* ]] && [ -n "$expected_dir" ]; then
                local extracted_dir
                extracted_dir=$(find . -maxdepth 1 -type d -name "llvm-bpf-*" | head -n1)

                if [ -n "$extracted_dir" ]; then
                    # Fix: If expected_dir exists, mv puts extracted_dir INSIDE it, causing errors.
                    # We must remove the existing directory to ensure a clean rename.
                    if [ -d "$expected_dir" ]; then
                        rm -rf "$expected_dir"
                    fi
                    mv "$extracted_dir" "$expected_dir"
                fi
            fi
            rm -f "$file_name"
        fi
    else
        rm -f "$file_name"
        return 1
    fi
}

cleanup_on_exit() {
    local exit_code=$?
    # Ensure cursor is restored if script is interrupted
    tput cnorm 2>/dev/null || true
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        generate_error_log "$LOG_FILE"
    fi
    exit $exit_code
}

cleanup_on_failure() {
    # shellcheck disable=SC2181 # Explicit check logic preferred here
    if [ "$?" -ne 0 ] && [ "$BUILD_SUCCESSFUL" = false ]; then
        echo ""
        echo "❌ BUILD FAILED!"
        if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
             echo "--- Last 20 lines of build log ---"
             tail -n 20 "$LOG_FILE"
             echo "----------------------------------"
        fi
        echo "Caching current state..."
        mkdir -p "$PACKAGE_CACHE_DIR"
        if [ -d "dl" ]; then
            tar -I "zstd -T0" -cf "$PACKAGE_CACHE_DIR/dl_cache.tar.zst" dl 2>/dev/null || true
        fi
    fi
}

trap cleanup_on_exit EXIT
trap cleanup_on_failure ERR


# =========================================================================
# === 2. CONFIGURATION PHASE (INTERACTIVE) ===
# =========================================================================

echo "════════════════════════════════════════════════════════════════════════════════════"
echo "   OPENWRT BUILD CONFIGURATION"
echo "   All questions are asked now. The rest of the process is automated."
echo "   Base Directory: $BASE_DIR"
echo "════════════════════════════════════════════════════════════════════════════════════"
echo ""

# A. Previous Build Check
CONF_CLEAN_BUILD=false
if [ -f "$BASE_DIR/.build_in_progress" ] && [ -d "$BASE_DIR/nss-base" ]; then
    echo "⚠️  PREVIOUS BUILD DETECTED"
    CHOICE=$(prompt_user_input "Continue previous build? [Y/n]" 10 "y")
    if [[ "${CHOICE,,}" == "n" || "${CHOICE,,}" == "no" ]]; then
        CONF_CLEAN_BUILD=true
    fi
else
    CONF_CLEAN_BUILD=true
fi

if [ "$CONF_CLEAN_BUILD" = true ]; then

    # B. Ccache
    CONF_INSTALL_CCACHE=false
    if ! command -v ccache &> /dev/null; then
        CHOICE=$(prompt_user_input "Install ccache (compiler cache)? [Y/n]" 10 "y")
        [[ "${CHOICE,,}" == "y" ]] && CONF_INSTALL_CCACHE=true
    fi

    # C. Tmpfs (RAM Build)
    CONF_USE_TMPFS=false
    CONF_TMPFS_SIZE="52G"
    if [ -f /run/.containerenv ] || [ -n "$DISTROBOX_ENTER_PATH" ] || [ -n "$TOOLBOX_PATH" ]; then
        if ! mount | grep -q "on ${BUILD_DIR_PATH} type tmpfs"; then
            CHOICE=$(prompt_user_input "Enable RAM-based builds (tmpfs)? [Y/n]" 10 "n")
            if [[ "${CHOICE,,}" != "n" && "${CHOICE,,}" != "no" ]]; then
                CONF_USE_TMPFS=true
                echo "Select size:"
                echo "  1) 52GB (default)"
                echo "  2) 64GB"
                echo "  3) Custom"
                TMP_OPT=$(prompt_user_input "Choice [1/2/3]" 10 "1")
                case "$TMP_OPT" in
                    2) CONF_TMPFS_SIZE="64G" ;;
                    3)
                        read -r -p "Enter size (e.g. 72G): " CUSTOM
                        [[ "$CUSTOM" =~ ^[0-9]+[GgMm]$ ]] && CONF_TMPFS_SIZE="${CUSTOM^^}"
                        ;;
                esac
            fi
        fi
    fi

    # D. Modules
    CONF_BUILD_MODULES=false
    CHOICE=$(prompt_user_input "Build all optional kernel modules? [y/N]" 10 "n")
    [[ "${CHOICE,,}" == "y" ]] && CONF_BUILD_MODULES=true

    # E. Custom Defaults
    CONF_APPLY_DEFAULTS=false
    if [ -d "$BASE_DIR/config_defaults" ] && [ "$(ls -A "$BASE_DIR/config_defaults" 2>/dev/null)" ]; then
        CHOICE=$(prompt_user_input "Apply custom config defaults from ./config_defaults? [Y/n]" 10 "y")
        [[ "${CHOICE,,}" == "y" ]] && CONF_APPLY_DEFAULTS=true
    fi

    # F. Menuconfig
    CONF_RUN_MENUCONFIG=false
    CHOICE=$(prompt_user_input "Open interactive Menuconfig? [Y/n]" 10 "y")
    [[ "${CHOICE,,}" == "y" ]] && CONF_RUN_MENUCONFIG=true
fi

# G. Build Options (Jobs & Verbosity)
echo ""
echo "Build Options:"

# 1. Thread Count Calculation
TOTAL_CORES=$(nproc 2>/dev/null || echo 1)
MAX_JOBS=$((TOTAL_CORES + 2))
BALANCED_JOBS=$((TOTAL_CORES * 3 / 4))
[ "$BALANCED_JOBS" -lt 1 ] && BALANCED_JOBS=1

echo "System has $TOTAL_CORES cores available."
echo "Select thread usage:"
echo "  1) Max Performance ($MAX_JOBS threads) - Default"
echo "  2) Usable System   ($BALANCED_JOBS threads) - Keeps system responsive"
echo "  3) Single Thread   (1 thread)   - For debugging compilation failures"

JOB_CHOICE=$(prompt_user_input "Select option [1-3]" 15 "1")
case "$JOB_CHOICE" in
    2) CONF_JOBS="$BALANCED_JOBS" ;;
    3) CONF_JOBS="1" ;;
    *) CONF_JOBS="$MAX_JOBS" ;;
esac

# 2. Verbosity
echo ""
echo "Select log verbosity:"
echo "  1) Animated (Default) - Shows progress spinner + log summary"
echo "  2) Verbose  (Debug)   - Shows full scrolling text"
VERB_CHOICE=$(prompt_user_input "Select option [1-2]" 10 "1")

CONF_VERBOSE_FLAG=""
CONF_LOG_FILE=""

if [ "$VERB_CHOICE" == "2" ]; then
    CONF_VERBOSE_FLAG="V=s"
    CONF_LOG_FILE="$BASE_DIR/build_verbose.txt"
else
    # Default/Animated mode: We still need a log file to show progress
    CONF_LOG_FILE="$BASE_DIR/build.log"
fi

# H. Post-Build Actions
CONF_UNMOUNT_TMPFS=false
if [ "$CONF_USE_TMPFS" = true ] || mount | grep -q "on ${BUILD_DIR_PATH} type tmpfs"; then
    CHOICE=$(prompt_user_input "Automatically unmount tmpfs (free RAM) after success? [y/N]" 9999 "n")
    [[ "${CHOICE,,}" == "y" ]] && CONF_UNMOUNT_TMPFS=true
fi

echo ""
echo "✓ Configuration complete. Starting build process..."
echo "════════════════════════════════════════════════════════════════════════════════════"
sleep 2


# =========================================================================
# === 3. EXECUTION PHASE (UNATTENDED) ===
# =========================================================================

# --- Step 0: Initial Cleanup ---
if [ "$CONF_CLEAN_BUILD" = true ]; then
    rm -f "$BASE_DIR/.build_in_progress"
    if [ -d "$BASE_DIR/nss-base" ]; then
        cd "$BASE_DIR/nss-base" && make clean 2>/dev/null || true
    fi
fi

if [ "$CONF_CLEAN_BUILD" = true ]; then

    # --- Step 1: System Prep ---
    if [ "$CONF_INSTALL_CCACHE" = true ]; then
        echo "[1/12] Installing ccache..."
        sudo apt-get update && sudo apt-get install -y ccache
    fi

    if [ "$CONF_USE_TMPFS" = true ]; then
        echo "[1.5/12] Mounting tmpfs ($CONF_TMPFS_SIZE)..."
        mkdir -p "$BUILD_DIR_PATH"
        if sudo mount -t tmpfs -o size="$CONF_TMPFS_SIZE" tmpfs "$BUILD_DIR_PATH"; then
            TMPFS_MOUNTED=true
            echo "$BUILD_DIR_PATH" > "$BASE_DIR/.tmpfs_mount_requested"
            echo "$CONF_TMPFS_SIZE" >> "$BASE_DIR/.tmpfs_mount_requested"
        else
            echo "❌ Failed to mount tmpfs. Proceeding on disk."
        fi
    fi

    # --- Step 2: Dependencies ---
    echo "[2/12] Verifying build dependencies..."
    sudo apt-get update
    sudo apt-get install -y build-essential clang flex bison g++ gawk \
        gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
        python3-setuptools rsync swig unzip zlib1g-dev file wget \
        python3 python3-dev python3-pip libpython3-dev curl libelf-dev \
        xsltproc libxml-parser-perl patch diffutils findutils quilt zstd \
        libprotobuf-c1 libprotobuf-c-dev protobuf-c-compiler

    # --- Step 3: Repositories ---
    echo "[3/12] Setting up repositories..."
    cd "$BASE_DIR" || exit 1

    clone_or_update_repo https://github.com/AgustinLorenzo/openwrt.git nss-base main_nss
    clone_or_update_repo https://github.com/jkool702/openwrt-custom-builds.git quality-base main-NSS

    mkdir -p quality-config
    cp quality-base/WRX36/bin/targets/qualcommax/ipq807x/config.buildinfo quality-config/
    [ -f "quality-base/WRX36/bin/targets/qualcommax/ipq807x/feeds.buildinfo" ] && cp quality-base/WRX36/bin/targets/qualcommax/ipq807x/feeds.buildinfo quality-config/

    # --- Step 4: Feeds ---
    echo "[4/12] Updating feeds..."
    cd "$BASE_DIR/nss-base" || exit 1
    clone_or_update_repo https://github.com/fantastic-packages/packages package/fantastic_packages snapshot
    ./scripts/feeds update -a && ./scripts/feeds install -a

    # --- Step 5: Config Import ---
    echo "[5/12] Importing configurations..."
    if [[ -d "${prev_files_dir_path}" ]]; then cp -r "${prev_files_dir_path}" ./; fi
    if [[ -f "${prev_kernel_config_path}" ]]; then cp "${prev_kernel_config_path}" .config.kernel.prev; else touch .config.kernel.prev; fi

    CONFIG_APPLIED=false
    if [[ -f "${prev_diff_config_path}" ]]; then
        cp "${prev_diff_config_path}" .config
        CONFIG_APPLIED=true
    elif [[ -f "${prev_full_config_path}" ]]; then
        cp "${prev_full_config_path}" .config
        CONFIG_APPLIED=true
    fi
    if [ "$CONFIG_APPLIED" = false ]; then
        cp "$BASE_DIR/quality-config/config.buildinfo" .config
    fi

    # --- Step 6: Critical Configs ---
    echo "[6/12] Applying NSS critical settings..."
    make defconfig
    {
        echo "CONFIG_TARGET_qualcommax=y"
        echo "CONFIG_TARGET_qualcommax_ipq807x=y"
        echo "CONFIG_TARGET_qualcommax_ipq807x_DEVICE_dynalink_dl-wrx36=y"
        echo "CONFIG_TARGET_ROOTFS_SQUASHFS=y"
        echo "CONFIG_TARGET_SQUASHFS_BLOCK_SIZE=256"
        echo "CONFIG_TARGET_ROOTFS_TARGZ=n"
        echo "CONFIG_TARGET_ROOTFS_EXT4FS=n"
        echo "CONFIG_TARGET_KERNEL_PARTSIZE=8192"
        echo "CONFIG_TARGET_ROOTFS_PARTSIZE=512"
        echo "# CONFIG_PACKAGE_kmod-ath11k-ahb is not set"
        echo "# CONFIG_PACKAGE_kmod-ath11k-pci is not set"
    } >> .config
    make defconfig

    # --- Step 7: Fixes & Tools ---
    echo "[7/12] Applying fixes and downloading tools..."

    # (Removed unreliable binutils fix from here; moved to Critical Fixes section below)

    if [ -f "include/cmake.mk" ] && ! grep -q "CMAKE_POLICY_VERSION_MINIMUM=3.5" include/cmake.mk; then
        sed -i '/^cmake_bool[[:space:]]*=/a CMAKE_OPTIONS += -DCMAKE_POLICY_VERSION_MINIMUM=3.5' include/cmake.mk
    fi

    # INLINED: apply_zstd_fix
    if [ -f "tools/zstd/Makefile" ] && ! grep -q "HOST_CFLAGS += -fPIC" "tools/zstd/Makefile"; then
        echo "HOST_CFLAGS += -fPIC" >> "tools/zstd/Makefile"
    fi

    download_prebuilt_artifact "llvm-bpf-.*\.tar\.zst" "llvm-bpf"
    download_prebuilt_artifact "kernel-debug.tar.zst" "kernel-debug.tar.zst"

    # --- Step 8: Package Logic ---
    echo "[8/12] Processing packages..."
    cd "$BASE_DIR" || exit 1
    grep "^CONFIG_PACKAGE_.*=y" quality-config/config.buildinfo | sed 's/CONFIG_PACKAGE_//g;s/=y//g' > quality-config/package-list.txt

    if [ "$CONF_BUILD_MODULES" = true ]; then
        grep "^CONFIG_PACKAGE_.*=m" quality-config/config.buildinfo | sed 's/CONFIG_PACKAGE_//g;s/=m//g' > quality-config/module-list.txt || touch quality-config/module-list.txt
        cat quality-config/module-list.txt >> quality-config/package-list.txt
    fi

    cd "$BASE_DIR/nss-base" || exit 1
    # Filtering Logic (Problematic packages)
    PROBLEMATIC_PACKAGES=("luci-app-pcap-dnsproxy" "pcap-dnsproxy" "luci-app-shadowsocks-rust" "shadowsocks-rust-config" "shadowsocks-rust-ssservice" "luci-app-einat" "einat-ebpf" "luci-app-alwaysonline" "alwaysonline" "uci-alwaysonline" "natmapt" "rgmac" "fakehttp" "bandix" "natter" "natter-ddns-script-cloudflare" "stuntman-client" "stuntman-server" "stuntman-testcode" "apk-mbedtls" "apk-openssl")

    filtered_package_list=$(mktemp)
    while IFS= read -r PACKAGE; do
        [ -z "$PACKAGE" ] && continue
        skip=0 # Removed LOCAL
        for prob in "${PROBLEMATIC_PACKAGES[@]}"; do [[ "$PACKAGE" == "$prob" ]] && skip=1 && break; done
        [[ $skip -eq 0 ]] && echo "$PACKAGE" >> "$filtered_package_list"
    done < "$BASE_DIR/quality-config/package-list.txt"

    while IFS= read -r PACKAGE; do echo "CONFIG_PACKAGE_$PACKAGE=y" >> .config; done < "$filtered_package_list"
    rm -f "$filtered_package_list"

    # --- Step 9: Final Config ---
    echo "[9/12] Finalizing Configuration..."
    if [ "$CONF_APPLY_DEFAULTS" = true ]; then
        mkdir -p files/etc/config
        cp "$BASE_DIR/config_defaults"/* "files/etc/config/"
    fi

    if [ "$CONF_RUN_MENUCONFIG" = true ]; then
        echo "Starting menuconfig (Waiting for user input)..."
        make menuconfig
    fi

    # Save diff
    mkdir -p "$BASE_DIR/config_defaults"
    ./scripts/diffconfig.sh > "$BASE_DIR/config_defaults/final.config.diff" || true

    # --- Step 10: Download ---
    echo "[10/12] Downloading Sources..."
    make download V=s || { echo "❌ ERROR: Download failed."; exit 1; }

    # --- Step 11: Kernel Prep ---
    echo "[11/12] Kernel Preparation..."
    make target/linux/clean
    make -j"$(nproc)" V=sc target/linux/prepare 2>&1 | tee -a "$BASE_DIR/kernel_prep.log"

    target_board=$(grep -E '^CONFIG_TARGET_[a-z]+=y' .config | sed -E 's/^CONFIG_TARGET_//;s/=y$//')
    builddir_kernel=$(find build_dir/target*/linux-${target_board}*/linux-* -maxdepth 1 -type d | head -n1)

    # INLINED: apply_kernel_tweaks
    if [ -n "$builddir_kernel" ] && [ -d "$builddir_kernel" ]; then
        echo "⚙️  Applying ARM v8-a optimization tweaks..."
        makefile="${builddir_kernel}/arch/arm64/Makefile"

        if [ -f "$makefile" ]; then
            if ! grep -q "asm-arch.*cortex-a53.*crc.*crypto" "$makefile"; then
                sed -i '/^asm-arch/s/=.*/= armv8-a+crc+crypto+rdma/' "$makefile" || \
                    echo "asm-arch := armv8-a+crc+crypto+rdma" >> "$makefile"
            fi
            if ! grep -q "\\-Wa,\\-mcpu=cortex-a53" "$makefile"; then
                sed -i '/^KBUILD_CFLAGS/s/$/ -Wa,-mcpu=cortex-a53+crc+crypto+rdma/' "$makefile" || \
                    echo "KBUILD_CFLAGS += -Wa,-mcpu=cortex-a53+crc+crypto+rdma" >> "$makefile"
            fi
            echo "✓ Kernel tweaks applied"
        else
            echo "⚠️  Makefile not found at $makefile"
        fi
    fi

fi # End of Clean Build Steps

# --- CRITICAL FIXES (Runs on Clean Build AND Resume) ---
cd "$BASE_DIR/nss-base" || exit 1

if [ -f "toolchain/binutils/Makefile" ]; then
    echo "🔧 Checking binutils configuration..."

    # 1. Reset the Makefile to ORIGINAL state (reverting our disable-patches)
    # This allows libsframe to build normally (Enabled) which solves the "No rule" error.
    git checkout toolchain/binutils/Makefile 2>/dev/null || true

    # 2. Apply FIX for OpenWRT Issue #13428 (Missing Install)
    # Since we enabled libsframe (by resetting), we must ensure it gets installed
    # to staging, otherwise downstream packages will fail to link against it.
    if ! grep -q "libsframe" "toolchain/binutils/Makefile"; then
        echo "   -> Applying OpenWRT Issue #13428 Fix (Copy libsframe to staging)..."
        # We find the installation command and append the copy instruction
        # We use a loose match on '$(MAKE) .* install' which is standard in OpenWRT makefiles
        sed -i '/$(MAKE) .* install/a \\t$(CP) $(TOOLCHAIN_DIR)/lib/libsframe.{a,so*} $(TOOLCHAIN_DIR)/lib/ || true' "toolchain/binutils/Makefile"
    fi

    # 3. FORCE CLEAN if reusing previous build (Critical for Resume)
    # We must wipe the "confused" build directory where we tried to disable it.
    if grep -q "libsframe" "toolchain/binutils/Makefile"; then
        echo "   -> Forcing deep clean of binutils to apply install fix..."

        # A. Delete the compiled build directories
        find build_dir -type d -name "binutils-2.44" -exec rm -rf {} + 2>/dev/null || true

        # B. Remove STAGING artifacts (Start fresh)
        find staging_dir -name "libbfd.la" -delete 2>/dev/null || true
        find staging_dir -name "libsframe.la" -delete 2>/dev/null || true

        # C. Remove build stamps to trick OpenWRT into re-running configure
        find build_dir -name ".built_*binutils*" -delete 2>/dev/null || true
        find build_dir -name ".configured_*binutils*" -delete 2>/dev/null || true
        find build_dir -name ".prepared_*binutils*" -delete 2>/dev/null || true

        # D. Run standard clean as a fallback
        make toolchain/binutils/clean 2>/dev/null || true

        # E. PRE-COMPILE BINUTILS SINGLE-THREADED
        echo "   -> Pre-compiling binutils (Single Threaded) to ensure libraries exist..."
        make toolchain/binutils/compile -j1 V=s

        echo "   ✓ Binutils reset & patched. Main build can proceed."
    fi
else
    echo "⚠️ Warning: toolchain/binutils/Makefile not found. Skipping fix."
fi


# --- Step 12: Build ---
echo "[12/12] Starting Final Compilation..."

# Determine Build Variables based on Phase 1 Selection
JOBS="$CONF_JOBS"
VERBOSE_FLAG="$CONF_VERBOSE_FLAG"
LOG_FILE="$CONF_LOG_FILE"

# Check for tmpfs mount request file from Phase 1 if we resumed
if [ -f "$BASE_DIR/.tmpfs_mount_requested" ] && [ "$TMPFS_MOUNTED" != true ] && ! mount | grep -q "on ${BUILD_DIR_PATH} type tmpfs"; then
    REQ_SIZE=$(sed -n '2p' "$BASE_DIR/.tmpfs_mount_requested")
    mkdir -p "$BUILD_DIR_PATH"
    sudo mount -t tmpfs -o size="$REQ_SIZE" tmpfs "$BUILD_DIR_PATH"
    TMPFS_MOUNTED=true
fi

# INLINED: restore_package_cache
if [ -d "$PACKAGE_CACHE_DIR" ]; then
    echo "📦 Restoring cached packages..."
    cd "$BASE_DIR/nss-base" || exit 1
    if [ -f "$PACKAGE_CACHE_DIR/staging_dir_cache.tar.zst" ]; then
        tar -I zstd -xf "$PACKAGE_CACHE_DIR/staging_dir_cache.tar.zst" -C . 2>/dev/null || true
    fi
    if [ -f "$PACKAGE_CACHE_DIR/dl_cache.tar.zst" ]; then
        tar -I zstd -xf "$PACKAGE_CACHE_DIR/dl_cache.tar.zst" -C . 2>/dev/null || true
    fi
    echo "✓ Cache restored"
fi

touch "$BASE_DIR/.build_in_progress"

# INLINED: run_build_step "all"
cd "$BASE_DIR/nss-base" || exit 1

if command -v ccache &> /dev/null; then
    export PATH="/usr/lib/ccache:$PATH"
    export CCACHE_DIR="$BASE_DIR/.ccache"
    mkdir -p "$CCACHE_DIR"
    ccache -M 10G
fi

if [ "$JOBS" -eq 0 ]; then
    parallel_jobs=$(($(nproc) + 2))
else
    parallel_jobs="$JOBS"
fi

# Build array for make arguments to avoid eval (SC2294)
MAKE_ARGS=(-j"$parallel_jobs")

# Use output-sync for parallel builds to keep logs readable (grouped by target)
if [ "$parallel_jobs" -gt 1 ]; then
    MAKE_ARGS+=("--output-sync=recurse")
fi

if [ -n "$VERBOSE_FLAG" ]; then
    MAKE_ARGS+=("$VERBOSE_FLAG")
fi

echo "Executing: make ${MAKE_ARGS[*]}"

# Handle logging and animation
if [ -n "$VERBOSE_FLAG" ]; then
    # Verbose Mode: Show everything to stdout + file
    make "${MAKE_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"
else
    # Default/Animated Mode: Hide raw output, show spinner + log file tail
    echo "   (Detailed build logs are being saved to $LOG_FILE)"
    make "${MAKE_ARGS[@]}" > "$LOG_FILE" 2>&1 &
    make_pid=$!

    show_loading_animation "$make_pid" "$LOG_FILE"

    wait "$make_pid"

    # Wait returns exit code of last command. Check if make failed.
    # Note: wait alone returns 0 if pid is gone, but we want the exit code.
    # Bash 'wait' usually returns the exit code of the job.
    if [ $? -ne 0 ]; then
        echo "❌ Build process exited with error."
        # The trap will handle the cache, but we print log tail here
        if [ -f "$LOG_FILE" ]; then
            echo "--- Last 20 lines of build log ---"
            tail -n 20 "$LOG_FILE"
            echo "----------------------------------"
        fi
        exit 1
    fi
fi

# Cache success
if command -v ccache &> /dev/null && [ -d "$CCACHE_DIR" ]; then
    tar -I "zstd -T0" -cf "$BASE_DIR/ccache.tar.zst" -C "$BASE_DIR" .ccache 2>/dev/null || true
fi

BUILD_SUCCESSFUL=true
echo ""
echo "=== BUILD SUCCESSFUL ==="

if [ -d "$FIRMWARE_DIR" ]; then
    echo "✓ Firmware images generated:"
    # shellcheck disable=SC2012 # ls -lh | awk is used for pretty printing, safe here
    ls -lh "$FIRMWARE_DIR"/*.bin "$FIRMWARE_DIR"/*.ubi 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
else
    echo "❌ ERROR: No firmware binaries found!"
    BUILD_SUCCESSFUL=false
fi

if [ "$CONF_UNMOUNT_TMPFS" = true ]; then
    sudo umount "$BUILD_DIR_PATH" 2>/dev/null && rm -f "$BASE_DIR/.tmpfs_mount_requested"
    echo "✓ tmpfs unmounted"
fi

if [ "$BUILD_SUCCESSFUL" = true ]; then
    rm -f "$BASE_DIR/.build_in_progress"
fi
