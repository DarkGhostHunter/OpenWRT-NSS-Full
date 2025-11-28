#!/bin/sh

# ANSI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

show_menu() {
    clear
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "      OpenWrt Configuration Tool         "
    echo -e "${YELLOW}=========================================${NC}"
    echo ""
    echo "--- FIREWALL & ACCESS ---"
    echo "1. Enable WAN Management Access (SSH, HTTP, HTTPS, Ping)"
    echo "   Use this if the router is connected to an upstream network"
    echo "   and you need to access it from the WAN side."
    echo ""
    echo "2. Disable Firewall Completely (DANGEROUS)"
    echo "   Stops firewall and sets default policies to ACCEPT."
    echo ""
    echo "3. Reset Firewall to Secure Defaults"
    echo "   Removes custom WAN access rules and re-enables firewall."
    echo ""
    echo "--- NETWORK MODE ---"
    echo "4. Convert to Managed Switch / Dumb AP"
    echo "   Bridges WAN to LAN. Gets IP from upstream router."
    echo "   Disables local DHCP server, DNS (Unbound), and Routing."
    echo ""
    echo "5. Revert to Router Mode (Factory Defaults)"
    echo "   Restores NAT, Routing, DHCP Server, DNS, and Static IP (10.0.0.1)."
    echo ""
    echo "0. Exit"
    echo ""
}

apply_wan_access() {
    echo -e "\n${GREEN}Enabling WAN Management Access...${NC}"
    
    # Ensure firewall service is enabled
    /etc/init.d/firewall enable

    # 1. Allow Ping (ICMP)
    uci set firewall.allow_ping_wan=rule
    uci set firewall.allow_ping_wan.name='Allow-Ping-WAN'
    uci set firewall.allow_ping_wan.src='wan'
    uci set firewall.allow_ping_wan.proto='icmp'
    uci set firewall.allow_ping_wan.target='ACCEPT'
    uci set firewall.allow_ping_wan.enabled='1'

    # 2. Allow SSH
    uci set firewall.allow_ssh_wan=rule
    uci set firewall.allow_ssh_wan.name='Allow-SSH-WAN'
    uci set firewall.allow_ssh_wan.src='wan'
    uci set firewall.allow_ssh_wan.dest_port='22'
    uci set firewall.allow_ssh_wan.target='ACCEPT'
    uci set firewall.allow_ssh_wan.enabled='1'
    # Handle list for proto
    uci -q delete firewall.allow_ssh_wan.proto
    uci add_list firewall.allow_ssh_wan.proto='tcp'

    # 3. Allow HTTP
    uci set firewall.allow_http_wan=rule
    uci set firewall.allow_http_wan.name='Allow-HTTP-WAN'
    uci set firewall.allow_http_wan.src='wan'
    uci set firewall.allow_http_wan.dest_port='80'
    uci set firewall.allow_http_wan.target='ACCEPT'
    uci set firewall.allow_http_wan.enabled='1'
    # Handle list for proto
    uci -q delete firewall.allow_http_wan.proto
    uci add_list firewall.allow_http_wan.proto='tcp'

    # 4. Allow HTTPS
    uci set firewall.allow_https_wan=rule
    uci set firewall.allow_https_wan.name='Allow-HTTPS-WAN'
    uci set firewall.allow_https_wan.src='wan'
    uci set firewall.allow_https_wan.dest_port='443'
    uci set firewall.allow_https_wan.target='ACCEPT'
    uci set firewall.allow_https_wan.enabled='1'
    # Handle list for proto
    uci -q delete firewall.allow_https_wan.proto
    uci add_list firewall.allow_https_wan.proto='tcp'

    uci commit firewall
    /etc/init.d/firewall restart
    
    echo -e "${GREEN}Done! Firewall restarted.${NC}"
    echo "Active rules checking..."
    uci show firewall | grep "Allow-.*-WAN"
}

disable_firewall() {
    echo -e "\n${RED}Disabling Firewall Service...${NC}"
    
    # 1. Stop the service
    /etc/init.d/firewall stop
    /etc/init.d/firewall disable
    
    # 2. VITAL: Set default policies to ACCEPT manually via iptables/nftables
    echo "Flushing tables and setting default policies to ACCEPT..."
    
    if command -v nft >/dev/null; then
        nft flush ruleset
        # Simple permissive config for nftables
        nft add table inet filter
        nft add chain inet filter input { type filter hook input priority 0 \; policy accept \; }
        nft add chain inet filter forward { type filter hook forward priority 0 \; policy accept \; }
        nft add chain inet filter output { type filter hook output priority 0 \; policy accept \; }
    else
        # Legacy iptables
        iptables -P INPUT ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -F
        iptables -t nat -F
        iptables -t mangle -F
    fi

    echo -e "${RED}Firewall stopped and flushed. ALL TRAFFIC ALLOWED.${NC}"
}

reset_defaults() {
    echo -e "\n${YELLOW}Resetting Firewall to Secure Defaults...${NC}"
    
    # Enable service
    /etc/init.d/firewall enable

    # Delete the named rules
    uci -q delete firewall.allow_ping_wan
    uci -q delete firewall.allow_ssh_wan
    uci -q delete firewall.allow_http_wan
    uci -q delete firewall.allow_https_wan
    
    uci commit firewall
    /etc/init.d/firewall restart
    echo -e "${GREEN}Done! WAN input is now blocked.${NC}"
}

enable_switch_mode() {
    echo -e "\n${YELLOW}Converting to Managed Switch (Dumb AP)...${NC}"
    echo "This will:"
    echo "  1. Bridge WAN port to LAN (br-lan)."
    echo "  2. Disable WAN routing."
    echo "  3. Set LAN to DHCP Client (gets IP from upstream)."
    echo "  4. Disable local DHCP server, DNS (Unbound), and Odhcpd."
    echo -e "${RED}WARNING: You will lose connection immediately!${NC}"
    echo -e "Reconnect using the new IP assigned by your main router."
    
    read -p "Are you sure? (y/N): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    # 1. Add WAN to Bridge
    # Find the section name for br-lan (usually @device[0])
    BR_SECTION=$(uci show network | grep "name='br-lan'" | cut -d'.' -f2)
    if [ -n "$BR_SECTION" ]; then
        uci add_list network.${BR_SECTION}.ports='wan'
    else
        echo -e "${RED}Error: Could not find br-lan device.${NC}"
        return
    fi

    # 2. Configure LAN as DHCP Client
    uci set network.lan.proto='dhcp'
    uci -q delete network.lan.ipaddr
    uci -q delete network.lan.netmask

    # 3. Disable WAN Interface logical config
    uci set network.wan.proto='none'
    uci set network.wan6.proto='none'

    # 4. Disable DHCP Server on LAN
    uci set dhcp.lan.ignore='1'

    uci commit network
    uci commit dhcp
    
    echo "Disabling Unbound and Odhcpd (Not needed in AP mode)..."
    /etc/init.d/unbound stop
    /etc/init.d/unbound disable
    /etc/init.d/odhcpd stop
    /etc/init.d/odhcpd disable

    echo "Applying network changes... Goodbye!"
    /etc/init.d/network restart
    exit 0
}

revert_router_mode() {
    echo -e "\n${YELLOW}Reverting to Router Mode...${NC}"
    echo "This will restore Static IP 10.0.0.1 and enable NAT/DHCP/DNS."
    
    read -p "Are you sure? (y/N): " confirm
    if [ "$confirm" != "y" ]; then return; fi

    # 1. Remove WAN from Bridge
    BR_SECTION=$(uci show network | grep "name='br-lan'" | cut -d'.' -f2)
    if [ -n "$BR_SECTION" ]; then
        uci del_list network.${BR_SECTION}.ports='wan'
    fi

    # 2. Restore LAN Static IP
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr='10.0.0.1'
    uci set network.lan.netmask='255.255.255.0'

    # 3. Restore WAN Interface
    uci set network.wan.proto='dhcp'
    uci set network.wan6.proto='dhcpv6'

    # 4. Enable DHCP Server
    uci delete dhcp.lan.ignore

    uci commit network
    uci commit dhcp
    
    echo "Re-enabling Unbound and Odhcpd..."
    /etc/init.d/unbound enable
    /etc/init.d/unbound start
    /etc/init.d/odhcpd enable
    /etc/init.d/odhcpd start

    echo "Applying changes... IP will be 10.0.0.1"
    /etc/init.d/network restart
    exit 0
}

# Main Loop
while true; do
    show_menu
    read -p "Select an option [0-5]: " choice
    case $choice in
        1) apply_wan_access; read -p "Press Enter to continue..." ;;
        2) disable_firewall; read -p "Press Enter to continue..." ;;
        3) reset_defaults; read -p "Press Enter to continue..." ;;
        4) enable_switch_mode ;;
        5) revert_router_mode ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done