#!/bin/sh

PKG_NAME="$1"

# Basic validation
if [ -z "$PKG_NAME" ]; then
    echo "Usage: $0 <config_name>"
    exit 1
fi

CONFIG="/etc/config/$PKG_NAME"
ROM_CONFIG="/rom/etc/config/$PKG_NAME"

# Condition 1 & 1.1: If file does not exist OR is empty
# [ ! -s ] returns true if file doesn't exist or size is 0
if [ ! -s "$CONFIG" ]; then
    exit 0 # Update needed
fi

# Condition 1.2: If file exists (implied by passing above) AND matches ROM
if [ -f "$ROM_CONFIG" ] && cmp -s "$CONFIG" "$ROM_CONFIG"; then
    exit 0 # Update needed
fi

# Condition 2 (Implicit): File exists, is not empty, and differs from ROM
exit 1 # No update needed