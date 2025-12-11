# OpenWRT with NSS and many QoL

This script builds OpenWRT from scratch for Dynalink DL-WRX36, with Network SubSystem, plus many Quality-of-Life packages and fixes.

It's based on [jkool702 build](https://github.com/jkool702/openwrt-custom-builds)[²](https://forum.openwrt.org/t/full-featured-custom-build-for-dynalink-dl-wrx36-ax3600/180168), but uses the up-to-date [Agustin Lorenzo NSS Build](https://github.com/AgustinLorenzo/openwrt). It was created mashing up a lot of AI like Claude, Grok, Gemini, Copilot and Mistral, a lot of trial-and-error, and credits. Lot of credits.

> [!WARNING]
>
> This build **tries** to save your device default configuration, but anyway, **save it before you flash** and then restore it. Some services will be disabled to avoid misconfiguration, and you will need to enable them again in `System → Startup`. Essentially, if `/etc/config/system` and `/etc/config/wireless` exist, these will be kept.

## Highlights:

* **Performance**
    * **NSS enabled:** Offloads network to custom hardware, less CPU usage.
    * **[CPU Pining](files/etc/init.d/smp_affinity):** CPU0 for generic tasks. Ethernet & Crypto on CPU1. WiFi on CPU2. NSS Queue in CPU1+CPU3. 
    * **Kernel tweaks:** Specific for Cortex-A53 arch. NEON (SIMD) enabled. CRC32, Crypto (AES/SHA1/SHA2) hardware accelerated.
    * **ZRAM 512MB:** Swap on compressed RAM with LZ4 compression to minimize flash wear on high memory pressure (like for huge AdBlock lists).  

* **Networking**
    * **`10.0.0.0`:** Home Network. With `odhcpd` for superior IPv6 management, `unbound` for private/secure DNS handling.
    * **`192.168.0.0`:** IoT Network. No router access, only Internet. Isolated. Home Network can reach it, not viceversa.
    * **`LAN4` for IoT:** For IoT Hubs (Nest, Hue Bridge, HomePod, Alexa, etc.). Connected to IoT network. Can be _restored_ to normal LAN if you want (disable this interface and add it to the `lan` interface).
    * **[Firewall Rules](files/usr/bin/add-wan-rules-to-firewall):** Included to expose any service of the router by clicking a checkbox on the firewall.
    * **[Adblock](https://github.com/openwrt/packages/blob/master/net/adblock/files/README.md)**: Because. With `unbound`, you can with just enabling the firewall rules to intercept DNS connections at port 53, for both `lan` and/or `iot`. 
    * **[Tailscale](https://tailscale.com/)**: Simple custom private network. With interface and zone. Router acts as exit node. Requires [minor setup](https://openwrt.org/docs/guide-user/services/vpn/tailscale/start). [Comes with custom panel](packages/luci-app-tailscale).
    * **[Zerotier](https://www.zerotier.com/)**: Advanced private cloud. Requires [minor setup](https://openwrt.org/docs/guide-user/services/vpn/zerotier). [Comes with custom panel](packages/luci-app-zerotier).
    * **Firewall, SQM and Interface setup scripts**: One-shot shell script to [configure your router the first time](#first-boot).

* **Goodies**
    * **[Plex Media Server](https://plex.tv):** Great Media Server. Comes with LUCI panel. Requires external storage.
    * **[miniDLNA](https://openwrt.org/docs/guide-user/services/media_server/minidlna):** Small DLNA server for simple media sharing. Not needed if you use Plex or its own DLNA server. Requires external storage.
    * **[Aria2](https://aria2.github.io/):** Powerful & simple downloader, with headers and BitTorrent. Comes with [AriaNG](https://github.com/mayswind/AriaNg). Requires external storage.
    * **[NetData](https://github.com/netdata/netdata):** Powerful system data visualizer. [Configured to be lean](files/etc/netdata/netdata.conf). Pinned to CPU0.
    * **[Watchcat](https://openwrt.org/docs/guide-user/advanced/watchcat):** Restarts the WAN interface if Internet down (because some ISP Routers are dumb).
    * **[Easy SMB shares](files/etc/ksmbd/ksmbd.conf.template.example):** Robust, easy to use `ksmbd` template to mount your SSD/HDD/NVMe. Hardcoded `SMBUSER:SMBPASSWORD`.
    * **[BanIP](https://openwrt.org/docs/guide-user/services/banip):** Want to block an IP, a Country, a DNS-over-HTTPS or a social network? Now you can, but you're on your own for the proper instructions.
    * **[TTYD](https://tsl0922.github.io/ttyd/) + [btop](https://github.com/aristocratos/btop):** Show btop statistics at port `7682` with single unique process (great if you don't want to use netstat) with zero permissions (`nobody:nogroup`). 

> [!NOTE]
> 
> All of these services are disabled by default, except for TTYD's btop at port `7682`. You can enable them in `System → Startup`, and/or their own LUCI panel.

### Build

* **Unattended:** Interactive part first, build is last step.
* **Offline:** Will work if there is no internet connection after you download everything.
* **TMPFS + CCACHE:** Can build on RAM if 60GB+ available. Auto-installs `ccache` for faster re-builds.

* **Critical Build Fixes (non-negotiable)**
    * **Binutils 2.44:** Injects a specific dependency rule (`all-bfd: all-libsframe`) to prevent race conditions during parallel builds.
    * **Kernel Makefile:** Uses a "Nuclear Option" to detect and sanitize corrupt `asm-arch` variables in the kernel Makefiles.
    * **Toolchain 3.5+:** Forces `-fPIC` for ZSTD host tools and enforces CMake policy version 3.5+ for those packages that still use the old version (and won't compile).

* **Packages**
    * **Sources:** Integrates `fantastic-packages` and custom configs from `jkool702`, except some useless packages (for this build)
    * **Exclusions:** Automatically filters out known unstable packages (e.g., `shadowsocks-rust`, `pcap-dnsproxy`, `stuntman`) to prevent build errors.

### Caveats

* **No remote packages:** Do not try to install packages from the Internet. You will need to compile them yourself and install manually, or you will have _a terrible time_. 
* **No attended sysupgrade:** You cannot "upgrade" to newer _generic_ builds. It's disabled. Compile the firmware yourself.

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
cd openwrt-build && git pull && ./build.sh
```

4. Grab a cup of coffee and be ready to dive into the never-ending odyssey of building a custom OpenWRT firmware for sake of _pErFoRmAnCe aNd cOnVeNiEnCe_. Firmware and packages will be at `workdir/openwrt/bin/targets/qualcommax/ipq807x/`.

5. Follow OpenWRT instructions to [flash your device](https://openwrt.org/toh/dynalink/dl-wrx36), or do the usual _SysUpgrade_ from LUCI or SSH.

6. Router will reboot with the freshly flashed firmware. If you want some peace of mind, you can always restart so all changes are applied, but it shouldn't be necessary. 

> [!NOTE]
>
> If your SSH commands output something like `ssh_dispatch_run_fatal: ... error in libcrypto`, you will need to use SSH with some older crypto to connect. Without modifying your system, just run podman/docker and run the command inside it.
>
> ```shell
> podman run -it --rm --network=host \
> docker.io/alpine:3.19 \
> /bin/sh -c "apk add --no-cache openssh-client && ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa admin@192.168.1.1"
> ```

---

## First boot

### 1. WiFi and Usteer

You will probably want to change both your WiFi SSID on both antennas into something like "MyOffice". Every time you change them, you will have to get into usteer configuration and point these WiFi SSID to be _steered_. This way, your devices will roam between both antennas depending on signal quality.

Usteer already has some good-for-anything defaults about minimum signal strength and offset.

> [!NOTE]
> 
> As a rule of thumb, use wider channels for 5GHz if your _Channel Analysis_ (under _Status_) shows very far neighbors with very low noise. Otherwise, stick with a narrower channel for better reach.

### 2. Guest Network

In some places, you may want to offer a "Guest network" so your guest can access the Internet through your router instead of relaying on celular (3G/4G/5G). If that your case, use the `configure-guest` script to create/remove a guest network and SSID.

```shell
configure-guest
```

This script will create the "guest" interface, an SSID on the 5GHz antenna, and isolate the interface from other networks. Devices on this interface are isolated from each other.

### 3. Add WebApps

Some handy tools that I always use are [Sharevb's fork](https://github.com/sharevb/it-tools) of [IT Tools](https://it-tools.tech/) and [BentoPDF](https://bentopdf.com/).

Of course, these won't work without Internet, so I included a small script called `webapps` that downloads the latest versions and makes it available at a hardcoded port by reusing `uhttpd`. Just run `webapps` to install or remove them.

```shell
webapps install it-tools
```

The script will download, repack them into SquashFS and mount it into `uhttpd` web server. Also, it will create rules in `uhttpd` to serve them in a hard-coded port. 

> [!NOTE]
> 
> Webapps require a mounted external storage at `/mnt/sda1`, since these install at `/mnt/sda1/.webapps`.

### 4. Configure your firewall

The [`configure-firewall`](files/usr/bin/configure-firewall) script disables the firewall entirely, allows OpenWRT management and ports accessible from `wan` (outside), or restores the defaults (enabled).

If your OpenWRT router sits as a Dumb AP, you will probably want to access the management from the same network, so run this script first.

### 5. Configure your Interfaces

The [`configure-interface`](files/usr/bin/configure-interface) script changes the router between the default Router mode, and the Managed Switch / Dumb AP without firewall.

If your OpenWRT router won't be the main router, run that script first. Preferably, connect the WAN interface to your upstream router LAN ports, and it should be working immediately. 

### 4. Speedtest to SQM tuning

The [`speedtest-to-sqm`](files/usr/bin/speedtest-sqm) script configures SQM rules by _speedtesting_ your Internet. 

If your Internet connection gets unstable (unresponsive browsing, high latency, unstable videocalls) when being saturated, you may be victim of _bufferbloat_. Use this script to add rules to the traffic so prioritize network packets over others. 

You may test [your bufferbloat here](https://www.waveform.com/tools/bufferbloat). Usually asymmetric Internet connections (high download, low download) suffer from this.

---

## FAQ

* **Do you plan to add that/this/my/her/his device?**

No, unless I use it. I only use one and it works great.

* **My build fails, can you help me?**

Check the error logs, upload it to an AI and check what fix returns.

* **The AI says I should edit something inside the `feeds` directory**

Do not. Asks for a non-invasive fix. Post it here or make it a PR to integrate it to the script. Only put small fixes. 

* **Why `unbound` uses around 250MB of RAM!?**

Because Adblock loads its source list of banned ip into unbound, hence why it consumes so much RAM. Still, around 50% of RAM left for anything.

If you're using this router behind a network as a bridge or DNS is handled elsewhere, you may disable Adblock since this would be handled upstream.

* **Help! My router restarts every 15 minutes or so!**

It's because [Watchcat](files/etc/uci-defaults/z4-watchcat) default configuration. It will restart the **WAN interface** there is no Internet connection for 15 minutes.

If you are offline, disable it through the LUCI panel, via SSH (`/etc/init.d/watchcat disable && /etc/init.d/watchcat stop`) or just delete the rules.

* **Can you include Jellyfin instead of Plex?**

No, mostly because you will need Docker/Podman or [`chroot`](https://openwrt.org/docs/guide-user/services/chroot), and I'm not familiar with that setup. I would if someone decided to create a small package for it, like [I did for Plex Media Server](packages/luci-app-plexmediaserver).

* **My router DHCP server dies and I have to resort to use manual DHCP config**

Remove your DHCP static leases from `etc/config/dhcp` (`Network → DHCP → Leases`) and restart `odhcpd` (`service odhcpd restart`). If it doesn't fail, then **ensure all your static leases have a valid MAC address**. Use `02:xx:xx:xx:xx:xx` as placeholder if necessary. 

* **I'm a heavy VPN user. What can I do for better performance?**

Get a bigger router? Apart from that, not much. You won't get 1Gbps+ speeds due to [NSS currently not handling this kind of traffic natively](https://github.com/qosmio/openwrt-ipq?tab=readme-ov-file#nss-support-matrix):

- TLS/DTLS is not available for NSS firmware 11.4-12.5, required for OpenVPN.
- IPSEC is not available for NSS firmware 11.4-12.5, required for WireGuard (Tailscale and Headscale).
- NSS offloading is not compatible with user-space load, like ZeroTier.

The only resort is to move your VPN processes to the same core handled by NSS to keep them close to the CPU cache for latency.

Start the `/etc/init.d/smp_affinity_vpn` service to apply the changes, and restart the network. It will move the encryption engine and the processes to CPU3.

```shell
/etc/init.d/smp_affinity_vpn start
/etc/init.d/smp_affinity_vpn enable
/etc/init.d/network restart
```

To disable this, just restart the standard `spm_affinity` service to go back to the normal CPU pinning, disable the vpn-related service and restart the network.

```shell
/etc/init.d/spm_affinity restart
/etc/init.d/smp_affinity_vpn disable
/etc/init.d/network restart
```

* **Will you keep updated this?**

Until it hits the next OpenWRT stable release, and then it will stay there until there meaningful performance optimizations for the network stack, which after NSS I don't see meaningful except for VPN (TLS/DTLS, IPSEC).

So yes, but I don't expect flashing this every month on the Router.