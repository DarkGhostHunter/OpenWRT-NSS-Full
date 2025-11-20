# OpenWRT with NSS and many QoL

This script builds OpenWRT from scratch for Dynalink DL-WRX36, with Network SubSystem, plus many Quality-of-Life packages and fixes.

It's uses on [Agustin Lorenzo NSS Build](https://github.com/AgustinLorenzo/openwrt), and adds [jkool702 package improvements](https://github.com/jkool702/openwrt-custom-builds), like adding Plex Server. It was created mashing up a lot of AI like Claude, Grok, Gemini, Copilot and Mistral, a lot of trial-and-error, and credits.

## Features:
 - NSS Build, lowering the CPU burden.
 - Many packages like AdBlock, Usteer (for making devices roam between 5GHz and 2.4GHz antennas seamlessly)

## The ugly

Since this is a custom built firmware, you will need to compile your own additional packages if you want to install them later into the router. **You cannot download packages from the official feeds**.

---

> [!IMPORTANT]
>
> This build is recommended to be made under a Debian:13 Distrobox, or you will have a _really_ bad time. Also, if you have plenty of RAM, you should allocate no less than 52GB to the build folder if you want to speed up your build to the maxmimum.

---

The entire build process can be broken down into the following ordered steps:

## Firmware Build Process Summary

1.  **Build Performance Setup [0/11]**:
    * **Installs ccache** (compiler cache) to speed up future rebuilds.
    * **Prompts and handles the setup for a RAM-based build directory (`tmpfs`)** to accelerate compilation, especially when running inside a container environment like Distrobox.

2.  **Install Build Dependencies [1/10]**:
    * Uses `sudo apt-get install` to ensure all necessary Debian packages and libraries required by the OpenWrt build system (including `clang`, `zstd`, `libelf-dev`, etc.) are installed on the host system.

3.  **Setup Directory Structure [2/10]**:
    * Creates the primary working directory structure, typically `~/openwrt`.

4.  **Clone NSS Base Repository [3/10]**:
    * Clones or updates the **AgustinLorenzo/openwrt** Git repository (the NSS base) into the `~/openwrt/nss-base` directory.

5.  **Download Quality Build Configuration [4/10]**:
    * Clones or updates the **jkool702/openwrt-custom-builds** repository to obtain the pre-configured `config.buildinfo` and `feeds.buildinfo` specific to the DL-WRX36 device.

6.  **Prepare Build Environment [5/10]**:
    * Clones the `fantastic-packages/packages` feed.
    * Runs `./scripts/feeds update -a` and `./scripts/feeds install -a` to download package definitions and install them into the build system.

7.  **Apply Configuration and Import Files [6/10]**:
    * Imports optional custom files (like the `files/` directory or previous kernel/main configurations) specified by the user's script variables.
    * Applies the main configuration (`.config`) using the downloaded Quality build configuration as the fallback if no custom config is provided.

8.  **Update Configuration [7/10]**:
    * Runs `make defconfig` to expand the current `.config` and merge in new default options.
    * Appends **critical build options** to the `.config` to ensure the correct target (Dynalink DL-WRX36), subtarget, and firmware settings are enabled.
    * Applies a global **CMake policy fix** in `include/cmake.mk` required for some packages that use the old CMAKE (otherwise, some packages won't compile. [See this for more information](https://github.com/openwrt/packages/issues/27607)).

9.  **Download Prebuilt Artifacts [7.5/10]**:
    * Uses the dynamically version-aware `download_prebuilt_artifact` function to fetch the latest **`llvm-bpf-*.tar.zst`** toolchain. This step is critical for faster eBPF program compilation during the main build.
    * Downloads **`kernel-debug.tar.zst`**.

10. **Create Package Installation List [8/10]**:
    * Parses the Quality build's configuration file to create separate lists for packages to be built into the firmware (`=y`) and optional modules (`=m`).
    * **Prompts the user** whether to include all optional modules in the final build to install later in-device, or not.

11. **Integrate Packages [9/10]**:
    * Appends the combined list of required packages and selected modules to the `.config`.
    * Runs `make defconfig` one last time to validate and finalize the full package selection.

12. **Final Configuration and Settings [10/10]**:
    * Checks for and **prompts the user** to apply custom configuration files (e.g., network settings) to the firmware's overlay (`files/etc/config`).
    * **Prompts the user** to open `make menuconfig` for any final manual adjustments.
    * Generates a final difference file (`final.config.diff`) for reference.

13. **Build Execution & Caching**:
    * Prompts the user to select the **build intensity** (e.g., multi-threaded quiet or single-threaded verbose).
    * Mounts the `tmpfs` build directory and **restores package caches** from previous failed builds to resume progress.
    * Executes the build using `make download` (to fetch source archives) and then `make all` (to compile the firmware).
    * If successful, the **ccache** directory is compressed and saved.

14. **Post-Build Cleanup**:
    * Confirms the build completion and lists the final firmware images (`.bin` or `.ubi`) located in the `bin/targets` directory.
    * **Prompts the user** to unmount the `tmpfs` directory to free up system RAM.
    * Removes the `.build_in_progress` marker to indicate the process is complete.

---

Since this is done over OpenWRT snapshots, development is a moving target, so whatever could be built today may not tomorrow because something broke. PR's are welcome to apply fixes.
