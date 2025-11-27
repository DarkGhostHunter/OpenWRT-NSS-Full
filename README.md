# OpenWRT with NSS and many QoL

This script builds OpenWRT from scratch for Dynalink DL-WRX36, with Network SubSystem, plus many Quality-of-Life packages and fixes.

It's uses on [Agustin Lorenzo NSS Build](https://github.com/AgustinLorenzo/openwrt), and adds [jkool702 package improvements](https://github.com/jkool702/openwrt-custom-builds), like adding Plex Server. It was created mashing up a lot of AI like Claude, Grok, Gemini, Copilot and Mistral, a lot of trial-and-error, and credits.

## Features:
 - NSS Build, lowering the CPU burden.
 - `10.0.0.0` home network, `192.168.0.0` for IoT devices.
 - Adde Aria2 because sometimes you want to download something while you sleep.
 - Port 4 ready for dumb AP (as a bridge for IoT devices), that can be changed into a normal port later.
 - Many packages like AdBlock, Usteer (for making devices roam between 5GHz and 2.4GHz antennas seamlessly) and else.
 - Plex Media Server script (don't go overboard, this CPU is like a [Motorola Moto G5 Plus](https://www.gsmarena.com/motorola_moto_g5_plus-8453.php) from 2017).

## The ugly

Since this is a custom built firmware, you will need to compile your own additional packages if you want to install them later into the router. **You cannot download packages from the official feeds**.

---

> [!IMPORTANT]
>
> This build is recommended to be made under a Debian:13 Distrobox, or you will have a _really_ bad time. Also, if you have plenty of RAM, you should allocate no less than 52GB to the build folder if you want to speed up your build to the maxmimum.

---

## Features

In cause you didn't check the source repositories, here is a gist of what this script does to OpenWRT:

### Firmware Configuration & Optimization
* **Target:** Dynalink DL-WRX36 (Qualcomm IPQ807x) with **Cortex-A53** optimizations (CRC, Crypto, RDMA).
* **Storage Layout:**
    * **Partitions:** Kernel increased to **16MB**; RootFS reduced to **112MB**.
    * **Filesystem:** SquashFS (256 block size) enabled; Ext4 and TarGz disabled.
    * **Flash Protection:** Enables **ZRAM** (swap on compressed RAM) and forces **ZSTD compression** for UBIFS to minimize flash wear.
* **NSS Support:** Builds from NSS-specific branches and explicitly disables standard `ath11k` drivers to avoid conflicts.

### Critical Build Fixes
* **Binutils 2.44:** Injects a specific dependency rule (`all-bfd: all-libsframe`) to prevent race conditions during parallel builds.
* **Kernel Makefile:** Uses a "Nuclear Option" to detect and sanitize corrupt `asm-arch` variables in the kernel Makefiles.
* **Toolchain:** Forces `-fPIC` for ZSTD host tools and enforces CMake policy version 3.5+.

### Package Management
* **Sources:** Integrates `fantastic-packages` and custom configs from `jkool702`.
* **Exclusions:** Automatically filters out known unstable packages (e.g., `shadowsocks-rust`, `pcap-dnsproxy`, `stuntman`) to prevent build errors.
* **DHCP Static Leases**: Added a small package that allows to change DHCP static leases, absent when using `odhcpd` instead of `dnsmasq`.

### Default Config
* **User config and files**: Integrates the `files` directory to add custom configuration defaults.
* **My use case**: These files are for my use case, but also fixes some `unbound` weird defaults, a boot loop, and insane usteer configs.

### Automation
* **Workflow:** Separation of interactive configuration and unattended execution phases.
* **Performance:** Supports configurable RAM-based building (`tmpfs`) and auto-installs `ccache`.

---

## FAQ

* **Do you plan to add XXX device?**

No unless I use it. I've already one and works great.

* **My build fails, can you help me?**

Check the error logs, upload it to an AI and check what fix returns.

* **The AI says I should edit something inside the `feeds` directory**

Do not. Asks for a non-invansive fix. Post it here or make it a PR to integrate it to the script.

* **Why `unbound` uses around 250MB of RAM?**

Because Adblock loads its source list of banned ip into unbound, hence why it consumes so much RAM. Still, around 50% of RAM left for anything.

* **
