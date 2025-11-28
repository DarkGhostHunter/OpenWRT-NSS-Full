#!/bin/sh

# ANSI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

show_menu() {
    clear
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "   OpenWrt Firewall Configuration Tool   "
    echo -e "${YELLOW}=========================================${NC}"
    echo ""
    echo "1. Enable WAN Management Access (SSH, HTTP, HTTPS, Ping)"
    echo "   Use this if the router is connected to an upstream network"
    echo "   and you need to access it from the WAN side."
    echo ""
    echo "2. Disable Firewall Completely"
    echo "   WARNING: Stops and disables the firewall service."
    echo "   Only use this if the router is acting as a dumb AP/Bridge."
    echo ""
    echo "3. Reset to Secure Defaults (Block WAN Input)"
    echo "   Removes all custom WAN access rules and re-enables firewall."
    echo ""
    echo "0. Exit"
    echo ""
}

apply_wan_access() {
    echo -e "\n${GREEN}Enabling WAN Management Access...${NC}"
    
    # Ensure firewall service is enabled
    /etc/init.d/firewall enable

    uci batch <<EOF
        # 1. Allow Ping (ICMP)
        set firewall.allow_ping_wan=rule
        set firewall.allow_ping_wan.name='Allow-Ping-WAN'
        set firewall.allow_ping_wan.src='wan'
        set firewall.allow_ping_wan.proto='icmp'
        set firewall.allow_ping_wan.target='ACCEPT'
        set firewall.allow_ping_wan.enabled='1'

        # 2. Allow SSH
        set firewall.allow_ssh_wan=rule
        set firewall.allow_ssh_wan.name='Allow-SSH-WAN'
        set firewall.allow_ssh_wan.src='wan'
        delete firewall.allow_ssh_wan.proto
        add_list firewall.allow_ssh_wan.proto='tcp'
        set firewall.allow_ssh_wan.dest_port='22'
        set firewall.allow_ssh_wan.target='ACCEPT'
        set firewall.allow_ssh_wan.enabled='1'

        # 3. Allow HTTP
        set firewall.allow_http_wan=rule
        set firewall.allow_http_wan.name='Allow-HTTP-WAN'
        set firewall.allow_http_wan.src='wan'
        delete firewall.allow_http_wan.proto
        add_list firewall.allow_http_wan.proto='tcp'
        set firewall.allow_http_wan.dest_port='80'
        set firewall.allow_http_wan.target='ACCEPT'
        set firewall.allow_http_wan.enabled='1'

        # 4. Allow HTTPS
        set firewall.allow_https_wan=rule
        set firewall.allow_https_wan.name='Allow-HTTPS-WAN'
        set firewall.allow_https_wan.src='wan'
        delete firewall.allow_https_wan.proto
        add_list firewall.allow_https_wan.proto='tcp'
        set firewall.allow_https_wan.dest_port='443'
        set firewall.allow_https_wan.target='ACCEPT'
        set firewall.allow_https_wan.enabled='1'
EOF
    uci commit firewall
    /etc/init.d/firewall restart
    echo -e "${GREEN}Done! You should now be able to access the router via WAN IP.${NC}"
}

disable_firewall() {
    echo -e "\n${RED}Disabling Firewall Service...${NC}"
    /etc/init.d/firewall stop
    /etc/init.d/firewall disable
    echo -e "${RED}Firewall is now stopped and disabled.${NC}"
}

reset_defaults() {
    echo -e "\n${YELLOW}Resetting to Secure Defaults...${NC}"
    
    # Enable service just in case
    /etc/init.d/firewall enable

    # Delete the named rules
    uci delete firewall.allow_ping_wan 2>/dev/null
    uci delete firewall.allow_ssh_wan 2>/dev/null
    uci delete firewall.allow_http_wan 2>/dev/null
    uci delete firewall.allow_https_wan 2>/dev/null
    
    uci commit firewall
    /etc/init.d/firewall restart
    echo -e "${GREEN}Done! WAN input is now blocked.${NC}"
}

# Main Loop
while true; do
    show_menu
    read -p "Select an option [0-3]: " choice
    case $choice in
        1) apply_wan_access; read -p "Press Enter to continue..." ;;
        2) disable_firewall; read -p "Press Enter to continue..." ;;
        3) reset_defaults; read -p "Press Enter to continue..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done