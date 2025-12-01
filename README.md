# OpenWRT with NSS and many QoL

This script builds OpenWRT from scratch for Dynalink DL-WRX36, with Network SubSystem, plus many Quality-of-Life packages and fixes.

It's uses on [Agustin Lorenzo NSS Build](https://github.com/AgustinLorenzo/openwrt), and adds [jkool702 package improvements](https://github.com/jkool702/openwrt-custom-builds), like adding Plex Server. It was created mashing up a lot of AI like Claude, Grok, Gemini, Copilot and Mistral, a lot of trial-and-error, and credits. Lot of credits.

## Highlights:

* **Performance**
  * **NSS enabled:** Offloads network to custom hardware, less CPU usage. 
  * **[CPU Pining](files/etc/init.d/smp_affinity):** CPU0 for generic tasks. Ethernet & Crypto on CPU1. WiFi on CPU2. NSS Queue in CPU3.
  * **Kernel tweaks:** Specific for Cortex-A53 arch. NEON (SIMD) enabled. CRC32, Crypto (AES/SHA1/SHA2) hardware accelerated.
  * **ZRAM 512MB:** Swap on compressed RAM with ZSTD compression to minimize flash wear on high memory pressure.

* **Networking**
  * **`10.0.0.0`:** Home Network. With `odhcpd` for superior IPv6 management, `unbound` for secure private/secure DNS handling.
  * **`192.168.0.0`:** IoT Network. No router access, only Internet. Isolated. Home Network can reach it, not viceversa.
  * **LAN4 for IoT:** For IoT Hubs (Nest, Hue Bridge, HomePod, Alexa, etc.). Connected to IoT network. Can be _restored_ to normal LAN.
  * **[Adblock](https://github.com/openwrt/packages/blob/master/net/adblock/files/README.md)**: Because.
  * **[Tailscale](https://tailscale.com/) & [Zerotier](https://www.zerotier.com/)**: For your own custom private network. Requires manual UCI config.
  * **[`configure-firewall`](files/usr/bin/configure-firewall):** One-shot shell script to allow management accessible from WAN, disable firewall or restore defaults.
  * **[`configure-interface`](files/usr/bin/configure-interface):** One-shot shell script to switch between Managed Switch, Dumb AP and default Router.
  * **[`speedtest-to-sqm`](files/usr/bin/speedtest-sqm):** Configures SQM rules avoid [unstable Internet on heavy usage](https://www.waveform.com/tools/bufferbloat).
  * **[`speedtest-netperf`](files/usr/bin/speedtest-netperf):** Self-test for network.

* **Goodies**
  * **[Plex Media Server](https://plex.tv):** Great Media Server. Comes with LUCI panel. Requires external storage. 
  * **[Aria2](https://aria2.github.io/):** Powerful & simple downloader, with headers and BitTorrent. Comes with [AriaNG](https://github.com/mayswind/AriaNg).
  * **[NetData](https://github.com/netdata/netdata):** Powerful, system data visualizer. [Configured to be lean](files/etc/netdata/netdata.conf). Pinned to CPU0. Disabled by default because heavy first boot.
  * **[Watchcat](https://openwrt.org/docs/guide-user/advanced/watchcat):** Restarts the WAN interface if Internet down.
  * **[Easy SMB shares](files/etc/ksmbd/ksmbd.conf.template.example):** Robust, easy to use `ksmbd` template to mount your SSD/HDD/NVMe. Hardcoded `SMBUSER:SMBPASSWORD`.
  * **[BanIP](https://openwrt.org/docs/guide-user/services/banip):** Want to block an IP, a Country or a social network? Now you can.
  * **[TTYD](https://tsl0922.github.io/ttyd/):** Terminal on the web panel (because sometimes you don't have access to SSH).
  * 

### Build

* **Unattended:** Interactive part first, build is last step. 
* **Offline:** Will work if there is no internet connection (assuming downloaded everything).
* **TMPFS + CCACHE:** Can build on RAMS (if 60GB available). Auto-installs `ccache` for faster re-builds.

* **Critical Build Fixes (non-negotiable)**
  * **Binutils 2.44:** Injects a specific dependency rule (`all-bfd: all-libsframe`) to prevent race conditions during parallel builds.
  * **Kernel Makefile:** Uses a "Nuclear Option" to detect and sanitize corrupt `asm-arch` variables in the kernel Makefiles.
  * **Toolchain:** Forces `-fPIC` for ZSTD host tools and enforces CMake policy version 3.5+ for those packages that still use the old version (and won't compile).

* **Packages**
  * **Sources:** Integrates `fantastic-packages` and custom configs from `jkool702`, except some useless packages (for this build)
  * **Exclusions:** Automatically filters out known unstable packages (e.g., `shadowsocks-rust`, `pcap-dnsproxy`, `stuntman`) to prevent build errors.

### Caveats

* **No remote packages:** You cannot download packages. It's disabled. Compile them yourself and install manually.
* **No attended sysupgrade:** You cannot "upgrade" to newer _generic_ builds. It's disabled. Compile them yourself. 

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
cd openwrt-build && ./build.sh
```

4. Grab a cup of coffee and be ready to dive into the never-ending odyssey of building a custom OpenWRT firmware for sake of _pErFoRmAnCe aNd cOnVeNiEnCe_.

5. Follow OpenWRT instructions to [flash your device](https://openwrt.org/toh/dynalink/dl-wrx36), or do the usual _SysUpgrade_ from LUCI or SSH.

6. Router will reboot with the freshly flashed firmware, since chances are done live with reboot need. If you want some peace of mind, you can always restart the thing manually.

> [!NOTE]
>
> If your SSH commands output something like `ssh_dispatch_run_fatal: ... error in libcrypto`, you will need to use SSH with some older crypto to connect. Without modifying your system, just run podman/docker and run the command inside it.
> 
> ```shell
> podman run -it --rm --network=host \
  docker.io/alpine:3.19 \
  /bin/sh -c "apk add --no-cache openssh-client && ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa admin@192.168.216.1"
> ```

---

## After booting

### 1. WiFi and Usteer

You will probably want to change both your WiFi SSID on both antennas into something like "MyOffice". Every time you change them, you will have to get into usteer configuration and point these WiFi SSID to be _steered_. This way, your devices will roam between both antennas depending on signal quality.

Usteer already has some good-for-anything defaults about minimum signal strength and offset. 

### 2. Speedtest your Gigabit Internet

If you're a _heavy user_, you may want to run `speedtest-sqm`. It's a bash script that _should_ update SQM scripts depending on your connection download and upload speeds.

You may [test your bufferbloat here](https://www.waveform.com/tools/bufferbloat), and if you get C/D/F grades, you will need to set this through the script or manually. Also consider using this on low-speed connections, or if you always need minimum latency at all times (while downloads/uploads take a small penalty).

---

## FAQ

* **Do you plan to add that/this/my/her/his device?**

No, unless I use it. I only use one and it works great.

* **My build fails, can you help me?**

Check the error logs, upload it to an AI and check what fix returns.

* **The AI says I should edit something inside the `feeds` directory**

Do not. Asks for a non-invansive fix. Post it here or make it a PR to integrate it to the script.

* **Why `unbound` uses around 250MB of RAM!?**

Because Adblock loads its source list of banned ip into unbound, hence why it consumes so much RAM. Still, around 50% of RAM left for anything.

If you're using this router behind a network as a bridge or DNS is handled elsewhere, you may disable Adblock since this would be handled upstream.

* **Help! My router restarts every 15 minutes or so!**

It's because Watchcat configuration. It will restart the **WAN interface** there is no Internet connection for 15 minutes.

If you are offline, disable it through the LUCI panel, via SSH (`/etc/init.d/watchcat disable && /etc/init.d/watchcat stop`) or just delete the rules.

* **You're creating a kernel with the [RDMA](https://en.wikipedia.org/wiki/Remote_direct_memory_access). Are you sure?

No, I'm not sure, but doing so doesn't bring the router down, so probably it has it hidden somewhere? Well, it works.