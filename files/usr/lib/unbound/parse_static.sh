#!/bin/sh
. /lib/functions.sh

# 1. Configuration
# Output file location (must be in /var/lib/unbound to be visible to chroot)
OUTPUT_FILE="/var/lib/unbound/dhcp_static.conf"

# 2. Get Domain
# Try to get domain from Unbound config, then DHCP config, then default to 'lan'
DOMAIN=$(uci -q get unbound.@unbound[0].domain)
if [ -z "$DOMAIN" ]; then
    DOMAIN=$(uci -q get dhcp.@dnsmasq[0].domain)
fi
[ -z "$DOMAIN" ] && DOMAIN="lan"

# 3. Prepare File
echo "# Static leases parsed from /etc/config/dhcp for domain: $DOMAIN" > "$OUTPUT_FILE"

parse_host() {
    local cfg="$1"
    local name ip

    config_get name "$cfg" name
    config_get ip   "$cfg" ip

    # We only care about hosts that have both a Name and an IP
    if [ -n "$name" ] && [ -n "$ip" ] ; then
        # Write A record (IPv4)
        echo "local-data: \"$name.$DOMAIN. A $ip\"" >> "$OUTPUT_FILE"
        # Write PTR record (Reverse DNS)
        echo "local-data-ptr: \"$ip $name.$DOMAIN.\"" >> "$OUTPUT_FILE"
        echo "Parsed: $name.$DOMAIN -> $ip"
    fi
}

# 4. Execute Parser
config_load dhcp
config_foreach parse_host host

# 5. Integration Check
# This ensures the file is actually loaded by Unbound.
# We append an include line to unbound_ext.conf if it's not already there.
EXT_CONF="/var/lib/unbound/unbound_ext.conf"
if [ -f "$EXT_CONF" ]; then
    if ! grep -q "dhcp_static.conf" "$EXT_CONF"; then
        echo "include: \"$OUTPUT_FILE\"" >> "$EXT_CONF"
        echo "Added include to $EXT_CONF"
    fi
else
    echo "include: \"$OUTPUT_FILE\"" > "$EXT_CONF"
    echo "Created $EXT_CONF"
fi

# 6. Reload Unbound to apply changes
service unbound reload
echo "Unbound reloaded."