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
 - Comes with [NetData](), but disabled by default. If you're a data hoarder, you may enable it. Patience on the setup, it consumes all router resources, but eventually runs. Added configs to run on a router rather than a x86 rack.

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
    * **Partitions:** Kernel increased to **16MB**; RootFS reduced to **112MB**, just to avoid the internal NAND Flash wear (leaving the other half, 128MB, unused).
    * **Filesystem:** SquashFS (256 block size) enabled; Ext4 and TarGz disabled.
    * **Flash Protection:** Enables **ZRAM** (swap on compressed RAM) and forces **ZSTD compression** for UBIFS to minimize flash wear.
* **NSS Support:** Builds from NSS-specific branches and explicitly disables standard `ath11k` drivers to avoid conflicts.

### Critical Build Fixes
* **Binutils 2.44:** Injects a specific dependency rule (`all-bfd: all-libsframe`) to prevent race conditions during parallel builds.
* **Kernel Makefile:** Uses a "Nuclear Option" to detect and sanitize corrupt `asm-arch` variables in the kernel Makefiles.
* **Toolchain:** Forces `-fPIC` for ZSTD host tools and enforces CMake policy version 3.5+ for those packages that still use the old version (and won't compile).

### Package Management
* **Sources:** Integrates `fantastic-packages` and custom configs from `jkool702`, except some useless packages (for this build)
* **Exclusions:** Automatically filters out known unstable packages (e.g., `shadowsocks-rust`, `pcap-dnsproxy`, `stuntman`) to prevent build errors.

### Default Config
* **User config and files**: Integrates the `files` directory to add custom configuration defaults.
* **My use case**: These files are for my use case, but also fixes some `unbound` weird defaults, a boot loop, and insane usteer configs.
* **Plex Server Panel**: Yep, added a LUCI panels to handle your Plex Media Server without _sshing_ to configure it.

### Automation
* **Workflow:** Separation of interactive configuration and unattended execution phases.
* **Performance:** Supports configurable RAM-based building (`tmpfs`) and auto-installs `ccache`.

---

## How to install?

1. Create a Debian 13 (or later) container with [Distrobox](https://distrobox.it/), [Podman](https://podman.io/) or Docker.

```shell
distrobox create -i debian:13
```

2. Clone this repository on the directory of your choice inside the container, like `openwrt-build`

```shell
git clone --depth 1 --single-branch \
  https://github.com/DarkGhostHunter/OpenWRT-NSS-Full.git \
  openwrt-build
```

3. Execute the `build.sh` script.

```shell
cd openwrt-build

./build.sh
```

> [!NOTE]
>
> If it doesn't work, execute `chmod +x build.sh` to make the script executable. 


4. Grab a cup of coffee and be ready to dive into the never-ending oddisey of building a custom OpenWRT firmware for sake of pErFoRmAnCe.

5. Follow OpenWRT instructions to [flash your device](https://openwrt.org/toh/dynalink/dl-wrx36), or do the usual _SysUpgrade_.

> [!NOTE]
>
> If your SSH commands output something like `ssh_dispatch_run_fatal: ... error in libcrypto`, you will need to use SSH with some older crypto to connect. Without modifying your system, just run podman/docker and run the command inside it.
> 
> ```shell
> podman run -it --rm --network=host \
  docker.io/alpine:3.19 \
  /bin/sh -c "apk add --no-cache openssh-client && ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa admin@192.168.216.1"
> ```

The router will boot two times: once it applies the defaults it will boot again. Just wait patiently until 10.0.0.1 becomes availble.
---

## After booting

### 1. WiFi and Usteer

You will probably want to change both your WiFi SSID on both antennas into something like "MyOffice". Every time you change them, you will have to get into usteer configuration and point these WiFi SSID to be _steered_. This way, your devices will roam between both antennas depending on signal quality.

### 2. Speedtest your Gigabit Internet

If you're a _heavy user_, you may want to run `speedtest_to_sqm`. It's a bash script that _should_ update SQM scripts depending on your connection download and upload speeds.

You may [test your buffebloat here](https://www.waveform.com/tools/bufferbloat), and if you get C/D/F grades, you will need to set this through the script or manually. Also consider using this on low-speed connections, or if you always need minimum latency at all times (while downloads/uploads take a small penalty).

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
