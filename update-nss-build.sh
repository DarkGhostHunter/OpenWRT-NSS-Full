#!/bin/bash
# Script to update jkool702's Quality build with AgustinLorenzo's NSS base
# Run from ~/openwrt directory in Distrobox (Debian stable)

set -e          # Exit immediately if a command exits with a non-zero status
set -o pipefail # Fail if any command in a pipe (e.g. make | tee) fails

# =========================================================================
# === INSTRUCTIONS/NOTES FROM ORIGINAL build_instructions.bash (ADVISORY) ===
# Below are general build instructions/tweaks that may be required for a successful
# compile, particularly for older OpenWrt sources or specific NSS environments.

# NOTE ON REQUIRED TWEAKS (may or may not be required for current source):
#     1. Use the "package source override" for: unbound, libpcap, and libpfring.
#        This entails: clone the github repo somewhere outside the openwrt buildroot, then
#        cd to the "packages" folder for these and run `ln -s /path/to/cloned/git/repo/.git git-src`
#     2. After building the kernel, the "CMakeLists" for libpcap and usteer need minor modifications.
#        First "prepare" the buildroot for these packages by running:
#        `make package/feeds/packages/libpcap/prepare package/.../usteer/prepare`
#        For libpcap, add `set(___________ 0) to the first line of the CMakeLists file at builddir/.../libpcap/CMakeLists.txt`
#        For usteer, change the `Werror` to `Wno-error` in builddir/.../usteer-<ver>/CMakeLists.txt`
#     3. `tools/tar` requires you to be a non-root user to build.
#        To fix this, if you start as non-root and the build fails later due to permissions:
#        `sudo su`
#        `find ./ -user $SUDO_USER -exec chown -R root:root {} +`
#     4. Add `HOST_CFLAGS += -fPIC` to the zstd Makefile at tools/zstd/Makefile.
#
# THE FIXES SHOWN ABOVE ARE NOT INCLUDED IN THE BELOW BUILD SCRIPT!
# They may (or may not) be required to re-build an updated copy of the firmware from this repo.
# =========================================================================

# # # # # USER SPECIFIED OPTIONS (from build_instructions.bash)
# If set, these paths will override the config/files from the downloaded quality-base repo.
# Comment out (or unset) any you don't want automatically added.
prev_files_dir_path=""
prev_diff_config_path=""
prev_kernel_config_path=""
prev_full_config_path="" # ALT - If you have a previous full config

# =========================================================================
# === GLOBAL VARIABLES ===
# =========================================================================
LOG_FILE=""
BUILD_SUCCESSFUL=false
CCACHE_DIR=~/openwrt/.ccache
PACKAGE_CACHE_DIR=~/openwrt/package_cache
FIRMWARE_DIR=~/openwrt/nss-base/bin/targets/qualcommax/ipq807x
BUILD_DIR_PATH=~/openwrt/nss-base/build_dir
TMPFS_ALREADY_MOUNTED=false
BUILD_ALL_MODULES=false

# =========================================================================
# === HELPER FUNCTIONS ===
# =========================================================================

# Function to prompt the user with a timeout and default value
# Usage: prompt_user_input <message> <timeout> <default_choice>
prompt_user_input() {
    local message="$1"
    local timeout="$2"
    local default_choice="$3"
    
    echo -n "$message (auto-$default_choice in ${timeout}s): "
    
    local choice=""
    if read -t "$timeout" -r choice; then
        echo ""
    else
        echo ""
        echo "Timeout reached, defaulting to ${default_choice^^}"
        choice="$default_choice"
    fi
    
    echo "$choice"
}

# Function to generate error log from build log
generate_error_log() {
    local log_file="$1"
    
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📋 Generating filtered error/warning log..."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        local error_log="${log_file%.txt}_errors.txt"
        
        {
            echo "=========================================="
            echo "OpenWRT Build - Errors and Warnings"
            echo "=========================================="
            echo "Generated from: $(basename "$log_file")"
            echo "Date: $(date)"
            echo "=========================================="
            echo ""
            echo "Format: LINE_NUMBER: MESSAGE"
            echo ""
            echo "=========================================="
            echo ""
        } > "$error_log"
        
        # Filter for errors, command not found, and fatal issues (excluding "warning")
        grep -n -iE "(error|command not found|fatal|failed|cannot|unable to)" "$log_file" | grep -vi "warning" >> "$error_log" 2>/dev/null || true
        
        local error_count=$(grep -c "^[0-9]*:" "$error_log" 2>/dev/null || echo "0")
        
        echo "✓ Filtered log created: $error_log"
        echo "  Found $error_count lines with errors/warnings"
        echo ""
        echo "Complete log: $log_file"
        echo "Filtered log: $error_log"
        echo ""
    fi
}

# Function to clone or update a git repository
# Usage: clone_or_update_repo <repo_url> <target_dir> <branch>
clone_or_update_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local branch="$3"
    
    echo "Processing $target_dir..."
    if [ -d "$target_dir" ]; then
        echo "Directory exists, checking for updates..."
        cd "$target_dir"
        if [ -d ".git" ]; then
            echo "Updating existing repository (branch: $branch)..."
            git fetch origin
            git reset --hard origin/"$branch"
            git pull
        else
            echo "⚠️  Directory exists but is not a git repository."
        fi
        cd ..
    else
        echo "Cloning repository (branch: $branch, shallow clone)..."
        git clone --depth 1 --branch "$branch" "$repo_url" "$target_dir"
    fi
}

# Function to handle tmpfs mounting
handle_tmpfs_mount() {
    if mount | grep -q "on ${BUILD_DIR_PATH} type tmpfs"; then
        echo "✓ build_dir is already mounted as tmpfs"
        echo "  $(mount | grep "${BUILD_DIR_PATH}" | head -n1)"
        TMPFS_ALREADY_MOUNTED=true
        return 0
    fi
    
    local choice
    choice=$(prompt_user_input "Enable RAM-based builds? [Y/n]" 10 "y")
    
    case "${choice,,}" in
        n|no)
            echo "Skipping RAM-based builds."
            return 0
            ;;
        *)
            echo "Setting up RAM-based build directory..."
            echo ""
            echo "Select tmpfs size:"
            echo "  1) 52GB (default - sufficient for most builds)"
            echo "  2) 64GB (recommended for feature-complete builds)"
            echo "  3) Custom size"
            
            local tmpfs_choice
            tmpfs_choice=$(prompt_user_input "Choice [1/2/3]" 10 "1")
            
            local tmpfs_size="52G"
            case "$tmpfs_choice" in
                2)
                    tmpfs_size="64G"
                    echo "✓ Selected 64GB (feature-complete builds)"
                    ;;
                3)
                    echo -n "Enter custom size (e.g., 72G, 96G): "
                    read -r custom_size
                    if [[ "$custom_size" =~ ^[0-9]+[GgMm]$ ]]; then
                        tmpfs_size="${custom_size^^}"
                        echo "✓ Selected custom size: $tmpfs_size"
                    else
                        echo "Invalid size format. Using default 30GB"
                    fi
                    ;;
                *)
                    echo "✓ Selected 52GB (default)"
                    ;;
            esac
            
            # Create a marker file to indicate tmpfs should be mounted before build
            mkdir -p ~/openwrt
            echo "$BUILD_DIR_PATH" > ~/openwrt/.tmpfs_mount_requested
            echo "$tmpfs_size" >> ~/openwrt/.tmpfs_mount_requested
            
            echo ""
            echo "✓ RAM-based builds will be enabled before compilation"
            echo "  Size: $tmpfs_size"
            echo "  Location: $BUILD_DIR_PATH"
            ;;
    esac
}

# Function to restore package cache from a previous failed build
restore_package_cache() {
    if [ ! -d "$PACKAGE_CACHE_DIR" ]; then
        return 0
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 Detected cached packages from previous build"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Restoring compiled packages to avoid recompilation..."
    
    cd ~/openwrt/nss-base
    
    # Restore staging_dir
    if [ -f "$PACKAGE_CACHE_DIR/staging_dir_cache.tar.zst" ]; then
        echo " Restoring staging_dir..."
        tar -I zstd -xf "$PACKAGE_CACHE_DIR/staging_dir_cache.tar.zst" -C . 2>/dev/null || true
    fi
    # Restore compiled objects
    if [ -f "$PACKAGE_CACHE_DIR/compiled_objects_cache.tar.zst" ]; then
        echo " Restoring compiled objects..."
        tar -I zstd -xf "$PACKAGE_CACHE_DIR/compiled_objects_cache.tar.zst" -C . 2>/dev/null || true
    fi
    # Restore dl directory
    if [ -f "$PACKAGE_CACHE_DIR/dl_cache.tar.zst" ]; then
        echo " Restoring downloaded sources..."
        tar -I zstd -xf "$PACKAGE_CACHE_DIR/dl_cache.tar.zst" -C . 2>/dev/null || true
    fi
    echo "✓ Cache restored"
}

# Function to run a make step (download or full build)
# Usage: run_build_step <target> <jobs> <verbosity> <log_file>
run_build_step() {
    local target="$1"
    local jobs="$2"
    local verbosity="$3"
    local log_file="$4"
    local log_pipe=""

    cd ~/openwrt/nss-base

    # Setup ccache
    if command -v ccache &> /dev/null; then
        export PATH="/usr/lib/ccache:$PATH"
        export CCACHE_DIR=~/openwrt/.ccache
        mkdir -p "$CCACHE_DIR"
        ccache -M 10G
        echo "✓ ccache enabled with 10G limit"
    fi

    # Set parallel jobs
    local parallel_jobs
    if [ "$jobs" -eq 0 ]; then
        parallel_jobs=$(($(nproc) + 2))
        echo "Using $parallel_jobs parallel jobs"
        export MAKEFLAGS="-j$parallel_jobs"
    else
        parallel_jobs="$jobs"
        echo "Using $parallel_jobs single job"
        export MAKEFLAGS="-j$parallel_jobs"
    fi

    # Set logging
    if [ -n "$log_file" ]; then
        log_pipe="| tee -a \"$log_file\""
        echo "Output logged to: $log_file"
    fi

    # Perform the make command
    echo "Executing: make $target $verbosity -j$parallel_jobs $log_pipe"
    
    local build_start=$(date +%s)
    
    # Use eval to execute the command with the piped logging
    eval "make $target $verbosity $log_pipe"
    
    local build_end=$(date +%s)
    local build_duration=$((build_end - build_start))
    
    echo "$build_duration"
}


# =========================================================================
# === TRAP HANDLERS ===
# =========================================================================

# Trap to ensure error logs are generated even on failure
cleanup_on_exit() {
    local exit_code=$?
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        generate_error_log "$LOG_FILE"
    fi
    exit $exit_code
}
trap cleanup_on_exit EXIT

# Trap to cache compiled files on build failure
cleanup_on_failure() {
    if [ "$?" -ne 0 ] && [ "$BUILD_SUCCESSFUL" = false ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "❌ BUILD FAILED!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Caching successfully compiled packages (zstd)..."
        # Create cache directory for compiled packages
        mkdir -p "$PACKAGE_CACHE_DIR"
        
        # Cache staging_dir
        if [ -d "staging_dir" ]; then
            echo " Caching staging_dir..."
            tar -I "zstd -T0" -cf "$PACKAGE_CACHE_DIR/staging_dir_cache.tar.zst" staging_dir 2>/dev/null || true
        fi
        
        # Cache build_dir compiled objects
        if [ -d "build_dir" ]; then
            echo " Caching compiled objects (this may take a moment)..."
            # Use `find` to select specific compiled objects to save space
            find build_dir -name "*.so" -o -name "*.a" -o -name "*.ko" | \
                tar -I "zstd -T0" -cf "$PACKAGE_CACHE_DIR/compiled_objects_cache.tar.zst" -T - 2>/dev/null || true
        fi
        
        # Cache dl directory
        if [ -d "dl" ]; then
            echo " Caching downloaded sources..."
            tar -I "zstd -T0" -cf "$PACKAGE_CACHE_DIR/dl_cache.tar.zst" dl 2>/dev/null || true
        fi
        
        echo ""
        echo "✓ Cached successfully compiled components to $PACKAGE_CACHE_DIR"
        echo ""
    fi
}
trap cleanup_on_failure ERR

# =========================================================================
# === MAIN SCRIPT EXECUTION ===
# =========================================================================

# Check for build continuation
CONTINUE_BUILD=false
if [ -f ~/openwrt/.build_in_progress ] && [ -d ~/openwrt/nss-base ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⚠️  PREVIOUS BUILD DETECTED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    CHOICE=$(prompt_user_input "Continue previous build? [Y/n]" 10 "y")
    
    case "${CHOICE,,}" in
        n|no)
            echo "Starting fresh build. Cleaning previous state..."
            rm -f ~/openwrt/.build_in_progress
            cd ~/openwrt/nss-base
            make clean 2>/dev/null || true
            echo "✓ Cleaned previous build state"
            echo ""
            ;;
        *)
            echo "Continuing from previous build..."
            CONTINUE_BUILD=true
            ;;
    esac
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi

if [ "$CONTINUE_BUILD" = false ]; then

    echo "=== OpenWRT NSS Build Update Script ==="
    
    # Step 0: Build Performance Setup (ccache and tmpfs)
    echo "[0/11] Build Performance Setup"
    
    # CCACHE PROMPT
    if command -v ccache &> /dev/null; then
        echo "✓ ccache is already installed"
    else
        echo "ccache is a compiler cache that dramatically speeds up rebuilds."
        CHOICE=$(prompt_user_input "Install ccache? [Y/n]" 10 "y")
        if [[ "${CHOICE,,}" == "y" || "${CHOICE,,}" == "yes" ]]; then
            echo "Installing ccache..."
            sudo apt-get update && sudo apt-get install -y ccache
            echo "✓ ccache installed successfully"
        fi
    fi
    echo ""
    
    # TMPFS PROMPT
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⚡ PERFORMANCE TIP: RAM-based build directory"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ -f /run/.containerenv ] || [ -n "$DISTROBOX_ENTER_PATH" ] || [ -n "$TOOLBOX_PATH" ]; then
        echo "✓ Container environment detected (Distrobox/Toolbox)"
        handle_tmpfs_mount
    else
        echo "Running outside container environment. Skipping automated tmpfs setup."
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Press Enter to continue..."
    read -r

    # Step 1: Install required dependencies for Debian
    echo "[1/10] Installing build dependencies..."
    sudo apt-get update
    sudo apt-get install -y build-essential clang flex bison g++ gawk \
        gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
        python3-setuptools rsync swig unzip zlib1g-dev file wget \
        python3 python3-dev python3-pip libpython3-dev curl libelf-dev \
        xsltproc libxml-parser-perl patch diffutils findutils quilt zstd \
        libprotobuf-c1 libprotobuf-c-dev protobuf-c-compiler
    
    # Step 2: Create working directory structure
    echo "[2/10] Setting up directory structure..."
    cd ~
    mkdir -p openwrt/backup
    cd openwrt
    
    # Step 3: Clone or update the NSS repository (AgustinLorenzo)
    echo "[3/10] Cloning/updating NSS base repository..."
    clone_or_update_repo https://github.com/AgustinLorenzo/openwrt.git nss-base HEAD
    
    # Step 4: Download Quality build config and package list
    echo "[4/10] Downloading Quality build configuration..."
    cd ~/openwrt
    clone_or_update_repo https://github.com/jkool702/openwrt-custom-builds.git quality-base main-NSS
    
    # Copy config files from Quality build
    mkdir -p quality-config
    echo "Copying configuration files from Quality build..."
    if [ -f "quality-base/WRX36/bin/targets/qualcommax/ipq807x/config.buildinfo" ]; then
        cp quality-base/WRX36/bin/targets/qualcommax/ipq807x/config.buildinfo quality-config/
        echo "✓ Copied config.buildinfo"
    else
        echo "❌ ERROR: config.buildinfo not found in Quality repository"
        exit 1
    fi
    if [ -f "quality-base/WRX36/bin/targets/qualcommax/ipq807x/feeds.buildinfo" ]; then
        cp quality-base/WRX36/bin/targets/qualcommax/ipq807x/feeds.buildinfo quality-config/
        echo "✓ Copied feeds.buildinfo"
    fi
    
    # Step 5: Prepare the NSS base for building
    echo "[5/10] Preparing NSS base build environment..."
    cd ~/openwrt/nss-base
    
    # Add fantastic-packages
    echo "Cloning fantastic-packages/packages..."
    git clone --depth 1 --branch master --single-branch --no-tags --recurse-submodules https://github.com/fantastic-packages/packages package/fantastic_packages
    
    # Update and Install feeds
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    ./scripts/feeds install -a # Run install twice to catch all dependencies
    
    # Step 6: Apply Configuration and Import Previous Build Files
    echo "[6/10] Applying configuration and importing previous build files..."
    
    # 1. Copy in files/ directory from previous build (Override)
    if [[ "${prev_files_dir_path}" ]] && [[ -d "${prev_files_dir_path}" ]]; then
        echo "✓ Importing 'files/' directory from: ${prev_files_dir_path}"
        cp -r "${prev_files_dir_path}" ./
    fi
    
    # 2. Handle kernel config (.config.kernel.prev) (Override)
    if [[ "${prev_kernel_config_path}" ]] && [[ -f "${prev_kernel_config_path}" ]]; then
        echo "✓ Importing previous kernel config from: ${prev_kernel_config_path}"
        cp "${prev_kernel_config_path}" .config.kernel.prev
    else
        touch .config.kernel.prev
    fi
    
    # 3. Handle main config (.config) - Check user-specified paths first (Override)
    CONFIG_APPLIED=false
    if [[ "${prev_diff_config_path}" ]] && [[ -f "${prev_diff_config_path}" ]]; then
        echo "✓ Applying custom diffconfig as .config from: ${prev_diff_config_path}"
        cp "${prev_diff_config_path}" .config
        CONFIG_APPLIED=true
    elif [[ "${prev_full_config_path}" ]] && [[ -f "${prev_full_config_path}" ]]; then
        echo "✓ Applying custom full .config from: ${prev_full_config_path}"
        cp "${prev_full_config_path}" .config
        CONFIG_APPLIED=true
    fi
    
    # 4. If no user config applied, fall back to quality-base config
    if [ "$CONFIG_APPLIED" = false ]; then
        echo "Applying downloaded Quality build config..."
        cp ~/openwrt/quality-config/config.buildinfo .config
    fi
    
    # Step 7: Update the configuration for the new base
    echo "[7/10] Updating configuration for current NSS base..."
    
    # Function to apply critical config options
    apply_critical_config() {
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
    }
    
    # Expand the config to include all new options with defaults
    make defconfig
    
    echo "Applying critical build fixes for NSS firmware generation..."
    apply_critical_config >> .config
    
    # Re-run defconfig to clean up and validate
    make defconfig
    echo "✓ NSS firmware build configuration applied"
    
    # Apply global CMake policy fix to include/cmake.mk
    echo ""
    echo "Applying global CMake policy configuration..."
    if [ -f "include/cmake.mk" ]; then
        if ! grep -q "CMAKE_POLICY_VERSION_MINIMUM=3.5" include/cmake.mk; then
            sed -i '/^cmake_bool[[:space:]]*=/a CMAKE_OPTIONS += -DCMAKE_POLICY_VERSION_MINIMUM=3.5' include/cmake.mk
            echo "✓ Added CMAKE_POLICY_VERSION_MINIMUM=3.5 to include/cmake.mk"
        else
            echo "✓ CMAKE_POLICY_VERSION_MINIMUM already configured in include/cmake.mk"
        fi
    fi
    echo ""
    
    # Step 7.5: Download and setup prebuilt LLVM for faster eBPF builds
    echo "[7.5/10] Downloading prebuilt toolchain and SDK for faster builds..."
    
    # =========================================================================
    # === NEW FUNCTIONS TO FIND LATEST SNAPSHOT ARTIFACTS ===
    # =========================================================================

    # Function to find the latest versioned artifact name on the OpenWrt snapshot page
    # Usage: find_latest_artifact_name <artifact_pattern>
    find_latest_artifact_name() {
        local pattern="$1"
        local base_url="https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq807x"
        
        echo "🔎 Searching for latest version of: $pattern on $base_url..." >&2
        
        # Use curl to fetch the directory listing HTML, then grep/sed to find the filename
        local latest_file_name
        latest_file_name=$(
            curl -s "$base_url/" | \
            grep -oE "href=\"(${pattern}[^\"]+)\"" | \
            sed -E 's/href="([^"]+)"/\1/' | \
            head -n 1
        )
        
        if [ -n "$latest_file_name" ]; then
            echo "$latest_file_name"
        else
            echo ""
        fi
    }

    # Updated download function to resolve versioned files
    download_prebuilt_artifact() {
        local pattern="$1" # e.g., "llvm-bpf-*.tar.zst" or "kernel-debug.tar.zst"
        local expected_dir="$2"
        local base_url="https://downloads.openwrt.org/snapshots/targets/qualcommax/ipq807x"
        local file_name="$pattern" # Assume a hard-coded filename initially

        # Resolve pattern if it looks like a wildcard search (does not contain a specific version or name)
        if [[ "$pattern" == *"*"* ]]; then
            file_name=$(find_latest_artifact_name "${pattern}")
            if [ -z "$file_name" ]; then
                echo "❌ ERROR: Could not find latest artifact matching pattern: $pattern" >&2
                return 1
            fi
        fi
        
        # Check if a simple non-wildcard download is already present or extracted
        if [ -d "$expected_dir" ] || [ -f "$file_name" ]; then
            echo "✓ $(basename "$file_name") already present"
            return 0
        fi

        echo "Downloading $file_name..."
        wget -q --show-progress "$base_url/$file_name" -O "$file_name" || {
            echo "⚠️  Warning: Failed to download $file_name"
            rm -f "$file_name"
            return 1
        }
        
        if [[ "$file_name" == *.tar.zst ]]; then
            echo "Extracting $file_name..."
            tar --zstd -xf "$file_name" || {
                echo "⚠️  Warning: Failed to extract $file_name"
                rm -f "$file_name"
                return 1
            }
            
            # Move the extracted contents to the expected directory if a versioned folder was created
            if [[ "$file_name" == llvm-bpf-* ]] && [ -n "$expected_dir" ]; then
                local extracted_dir=$(find . -maxdepth 1 -type d -name "llvm-bpf-*" | head -n1)
                if [ -n "$extracted_dir" ]; then
                    mv "$extracted_dir" "$expected_dir"
                fi
            fi

            if [ -d "$expected_dir" ] || [ -f "$expected_dir" ]; then
                echo "✓ $expected_dir installed successfully"
            fi
            rm -f "$file_name"
        else
            echo "✓ $file_name downloaded successfully"
        fi
    }

    # =========================================================================
    # === MODIFIED MAIN EXECUTION SECTION ===
    # =========================================================================

    # Step 7.5: Download and setup prebuilt LLVM for faster eBPF builds
    echo "[7.5/10] Downloading prebuilt toolchain and SDK for faster builds..."
        
    # Download prebuilt artifacts
    # 1. Use pattern for LLVM-BPF to get the latest version (HIGHLY RECOMMENDED)
    download_prebuilt_artifact "llvm-bpf-*.tar.zst" "llvm-bpf"
        
    # 2. SDK download is usually redundant for a full firmware build (REMOVED/SKIPPED)
    # download_prebuilt_artifact "openwrt-sdk-*.tar.zst" "openwrt-sdk"
        
    # 3. Kernel debug remains the same (if still needed)
    download_prebuilt_artifact "kernel-debug.tar.zst" "kernel-debug.tar.zst"

    # ... (rest of the script) ...

    echo ""
    echo "Prebuilt artifacts summary:"
    if [ -d "llvm-bpf" ]; then
        echo "  ✓ LLVM-BPF toolchain (saves ~40 minutes)"
    fi
    if [ -f "kernel-debug.tar.zst" ]; then
        echo "  ✓ Kernel debug symbols"
    fi
    echo ""
    
    # Step 8: Extract package list from Quality build
    echo "[8/10] Creating package installation list..."
    cd ~/openwrt
    
    # Parse packages and modules
    grep "^CONFIG_PACKAGE_.*=y" quality-config/config.buildinfo | sed 's/CONFIG_PACKAGE_//g' | sed 's/=y//g' > quality-config/package-list.txt
    grep "^CONFIG_PACKAGE_.*=m" quality-config/config.buildinfo | sed 's/CONFIG_PACKAGE_//g' | sed 's/=m//g' > quality-config/module-list.txt || touch quality-config/module-list.txt
    
    MODULE_COUNT=$(wc -l < quality-config/module-list.txt)
    
    echo "Found $(wc -l < quality-config/package-list.txt) packages to build into firmware"
    echo "Found $MODULE_COUNT optional modules available"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "⚙️  FIRMWARE BUILD CONFIGURATION"
    CHOICE=$(prompt_user_input "Build all $MODULE_COUNT modules too? [y/N]" 15 "n")
    
    if [[ "${CHOICE,,}" == "y" || "${CHOICE,,}" == "yes" ]]; then
        echo "✓ Will build firmware + all $MODULE_COUNT optional modules"
        cat quality-config/module-list.txt >> quality-config/package-list.txt
        BUILD_ALL_MODULES=true
        echo "Total packages to build: $(wc -l < quality-config/package-list.txt)"
    else
        echo "✓ Will build firmware with core packages only"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Step 9: Install Quality packages in .config
    echo "[9/10] Integrating Quality build packages into .config..."
    cd ~/openwrt/nss-base
    
    echo "Setting all Quality packages to be built into the firmware (=y)..."
    while IFS= read -r PACKAGE; do
        echo "CONFIG_PACKAGE_$PACKAGE=y" >> .config
    done < ~/openwrt/quality-config/package-list.txt
    
    # Re-run defconfig to clean up and validate again
    make defconfig
    echo "✓ Package list applied and merged into configuration"
    
    # Step 10: Final configuration and custom settings
    echo "[10/10] Final configuration and custom settings..."
    
    # Apply custom configuration files
    CONFIG_DEFAULTS_DIR=~/openwrt/config_defaults
    if [ -d "$CONFIG_DEFAULTS_DIR" ] && [ "$(ls -A "$CONFIG_DEFAULTS_DIR" 2>/dev/null)" ]; then
        echo "✓ Found custom configuration directory with files."
        CHOICE=$(prompt_user_input "Apply these custom configurations to firmware? [Y/n]" 10 "y")
        
        if [[ "${CHOICE,,}" == "y" || "${CHOICE,,}" == "yes" ]]; then
            echo "Applying custom configurations to firmware..."
            cd ~/openwrt/nss-base
            mkdir -p files/etc/config
            local applied_count=0
            for config_file in "$CONFIG_DEFAULTS_DIR"/*; do
                if [ -f "$config_file" ]; then
                    filename=$(basename "$config_file")
                    cp "$config_file" "files/etc/config/$filename"
                    applied_count=$((applied_count + 1))
                fi
            done
            echo "✓ Copied $applied_count configuration file(s) to files/etc/config/"
        fi
    fi
    
    # Menuconfig prompt
    echo ""
    CHOICE=$(prompt_user_input "Press Enter to open menuconfig, or Ctrl+C to skip..." 9999 "")
    if [ -n "$CHOICE" ]; then
        make menuconfig
    fi
    
    # Create diffconfig for reference
    echo ""
    echo "Generating final .config.diff for reference..."
    mkdir -p ~/openwrt/config_defaults
    ./scripts/diffconfig.sh > ~/openwrt/config_defaults/final.config.diff || true
    echo "✓ Saved final config difference to ~/openwrt/config_defaults/final.config.diff"
fi # End of CONTINUE_BUILD check

# =========================================================================
# === BUILD EXECUTION ===
# =========================================================================

echo "=========================================="
echo "Ready to build firmware!"
echo "=========================================="
echo ""
echo "Build Configuration:"
echo "  System has $(nproc) CPU cores available"
echo "  Target: Dynalink DL-WRX36 (ipq807x)"
if [ "$BUILD_ALL_MODULES" = true ]; then
    echo "  Building ALL packages (firmware + modules)"
else
    echo "  Building firmware packages only"
fi
echo ""
echo "Build Options:"
echo "  1) Multi-threaded (FAST)   | Verbosity: Quiet  | Log: No"
echo "  2) Multi-threaded VERBOSE  | Verbosity: Full   | Log: Yes"
echo "  3) Single-threaded (SLOW)  | Verbosity: Quiet  | Log: No"
echo "  4) Single-threaded VERBOSE | Verbosity: Full   | Log: Yes"
echo "  5) Only perform download step"
echo ""

BUILD_CHOICE=$(prompt_user_input "Select option [1-5]" 15 "1")

# Mount tmpfs and restore cache before any build step
if [ -f ~/openwrt/.tmpfs_mount_requested ] && [ "$TMPFS_ALREADY_MOUNTED" != true ]; then
    TMPFS_SIZE=$(sed -n '2p' ~/openwrt/.tmpfs_mount_requested)
    mkdir -p "$BUILD_DIR_PATH"
    if sudo mount -t tmpfs -o size=$TMPFS_SIZE tmpfs "$BUILD_DIR_PATH"; then
        echo "✓ Mounted tmpfs for build_dir ($TMPFS_SIZE)"
        TMPFS_ALREADY_MOUNTED=true
    else
        echo "❌ ERROR: Failed to mount tmpfs. Proceeding without RAM-based build."
    fi
fi
restore_package_cache
touch ~/openwrt/.build_in_progress

BUILD_TARGET=""
JOBS=0 # 0 for multi-threaded (nproc+2)
VERBOSE_FLAG=""
LOG_FILE=""

case "$BUILD_CHOICE" in
    2)
        BUILD_TARGET="all"
        JOBS=0
        VERBOSE_FLAG="V=s"
        LOG_FILE=~/openwrt/openwrt_build_$(date +%Y%m%d_%H%M%S).txt
        echo "=== Starting MULTI-THREADED VERBOSE build ==="
        ;;
    3)
        BUILD_TARGET="all"
        JOBS=1
        VERBOSE_FLAG="V=s"
        echo "=== Starting SINGLE-THREADED build ==="
        ;;
    4)
        BUILD_TARGET="all"
        JOBS=1
        VERBOSE_FLAG="V=s"
        LOG_FILE=~/openwrt/openwrt_build_$(date +%Y%m%d_%H%M%S).txt
        echo "=== Starting SINGLE-THREADED VERBOSE build ==="
        ;;
    5)
        BUILD_TARGET="download"
        JOBS=0
        VERBOSE_FLAG="V=s"
        echo "=== Starting DOWNLOAD only build step ==="
        ;;
    1|*)
        BUILD_TARGET="all"
        JOBS=0
        VERBOSE_FLAG="" # Quiet output
        echo "=== Starting MULTI-THREADED build ==="
        ;;
esac

# Common execution logic for download and full build
if [ "$BUILD_TARGET" == "download" ] || [ "$BUILD_TARGET" == "all" ]; then
    
    if [ "$BUILD_TARGET" == "all" ]; then
        echo "Compiling firmware..."
        # First ensure all sources are downloaded, required for a clean separation of steps
        # We use separate calls for download and full build to allow for cache restoration in between
        echo "Running make download..."
        run_build_step "download" "$JOBS" "$VERBOSE_FLAG" "$LOG_FILE" || {
            echo "ERROR: Download step failed."
            exit 1
        }
    fi

    # Run the main build
    if [ "$BUILD_TARGET" == "all" ]; then
        BUILD_DURATION=$(run_build_step "all" "$JOBS" "$VERBOSE_FLAG" "$LOG_FILE")

        BUILD_MINUTES=$((BUILD_DURATION / 60))
        BUILD_SECONDS=$((BUILD_DURATION % 60))
        
        # Save ccache
        if command -v ccache &> /dev/null && [ -d "$CCACHE_DIR" ]; then
            echo "Saving compiler cache (zstd)..."
            tar -I "zstd -T0" -cf ~/openwrt/ccache.tar.zst -C ~/openwrt .ccache 2>/dev/null || true
        fi
        
        BUILD_SUCCESSFUL=true
        
        echo ""
        echo "=== BUILD SUCCESSFUL ==="
        echo "Build completed in ${BUILD_MINUTES}m ${BUILD_SECONDS}s"
    fi
    
    if [ "$BUILD_TARGET" == "download" ]; then
        echo ""
        echo "=== DOWNLOAD SUCCESSFUL ==="
        echo "Sources downloaded successfully."
        echo "You can now run 'make' manually."
    fi

    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        echo "Complete log saved to: $LOG_FILE"
    fi
fi

# =========================================================================
# === POST-BUILD CLEANUP ===
# =========================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$BUILD_SUCCESSFUL" = true ]; then
    if [ -d "$FIRMWARE_DIR" ] && (ls "$FIRMWARE_DIR"/*.bin 2>/dev/null || ls "$FIRMWARE_DIR"/*.ubi 2>/dev/null); then
        echo "✓ Firmware images successfully generated:"
        ls -lh "$FIRMWARE_DIR"/*.bin "$FIRMWARE_DIR"/*.ubi 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
        echo "Your firmware images are located at: $FIRMWARE_DIR/"
    else
        echo "❌ BUILD ERROR: No firmware binaries found!"
        BUILD_SUCCESSFUL=false # Override if binaries are missing
    fi
fi

# Clean up tmpfs
if [ "$TMPFS_ALREADY_MOUNTED" = true ] && [ -f ~/openwrt/.tmpfs_mount_requested ]; then
    echo "RAM-based build directory cleanup"
    echo "Path: $BUILD_DIR_PATH"
    
    CHOICE=$(prompt_user_input "Unmount build_dir from tmpfs? [y/N]" 9999 "n")
    
    if [[ "${CHOICE,,}" == "y" || "${CHOICE,,}" == "yes" ]]; then
        echo "Unmounting tmpfs..."
        if sudo umount "$BUILD_DIR_PATH" 2>/dev/null; then
            echo "✓ tmpfs unmounted successfully (RAM has been freed)"
            rm -f ~/openwrt/.tmpfs_mount_requested
        else
            echo "⚠️  Failed to unmount tmpfs. Manual unmount required: sudo umount $BUILD_DIR_PATH"
        fi
    else
        echo "Keeping tmpfs mounted for faster future builds."
    fi
fi

# Remove build in progress marker only if build was successful
if [ "$BUILD_SUCCESSFUL" = true ]; then
    rm -f ~/openwrt/.build_in_progress
else
    echo "The .build_in_progress marker remains. Run the script again to continue."
fi
