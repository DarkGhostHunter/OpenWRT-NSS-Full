#!/bin/bash

# Configuration
REPO="CorentinTh/it-tools"
OUTPUT_DIR="files/srv"
IMAGE_NAME="it-tools.squashfs"
VERSION_FILE="$OUTPUT_DIR/it-tools.version"
TEMP_DIR="/tmp/it-tools-build"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}IT Tools OpenWRT Installer${NC}"

# Check host dependencies
for cmd in curl jq mksquashfs unzip; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}Error: $cmd could not be found. Please install it.${NC}"
        exit 1
    fi
done

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

echo -e "${GREEN}Fetching latest release info from GitHub...${NC}"
LATEST_RELEASE=$(curl -s "https://api.github.com/repos/$REPO/releases/latest")
# Filter for the zip file that is NOT the source code
DOWNLOAD_URL=$(echo "$LATEST_RELEASE" | jq -r '.assets[] | select(.name | endswith(".zip")) | select(.name | contains("source") | not) | .browser_download_url' | head -n 1)
LATEST_VERSION=$(echo "$LATEST_RELEASE" | jq -r .tag_name)

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    echo -e "${RED}Error: Could not find a suitable release asset in $REPO${NC}"
    exit 1
fi

# Check current version
CURRENT_VERSION=""
if [ -f "$VERSION_FILE" ]; then
    CURRENT_VERSION=$(cat "$VERSION_FILE")
fi

IMAGE_PATH="$OUTPUT_DIR/$IMAGE_NAME"

# Decision Logic
if [ "$LATEST_VERSION" == "$CURRENT_VERSION" ] && [ -f "$IMAGE_PATH" ]; then
    echo -e "${GREEN}IT Tools is already up to date ($CURRENT_VERSION). Skipping installation.${NC}"
    exit 0
fi

if [ "$LATEST_VERSION" != "$CURRENT_VERSION" ]; then
    if [ -z "$CURRENT_VERSION" ]; then
        echo -e "Installing version: ${GREEN}$LATEST_VERSION${NC}"
    else
        echo -e "Update found: ${YELLOW}$CURRENT_VERSION${NC} -> ${GREEN}$LATEST_VERSION${NC}"
    fi
else
    echo -e "${YELLOW}Version matches ($LATEST_VERSION) but squashfs image is missing. Reinstalling...${NC}"
fi

# Prepare directories
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Download and unzip
echo -e "Downloading from: $DOWNLOAD_URL"
curl -L "$DOWNLOAD_URL" -o "$TEMP_DIR/it-tools.zip"
echo -e "${GREEN}Extracting...${NC}"
unzip -q "$TEMP_DIR/it-tools.zip" -d "$TEMP_DIR/extracted"

# Locate the actual dist folder
SITE_ROOT=$(find "$TEMP_DIR/extracted" -name "index.html" -printf "%h\n" | head -n 1)

if [ -z "$SITE_ROOT" ]; then
    echo -e "${RED}Error: Could not find index.html in the downloaded archive.${NC}"
    exit 1
fi

echo -e "Web root located at: $SITE_ROOT"

# Create SquashFS image
echo -e "${GREEN}Creating SquashFS image at $IMAGE_PATH...${NC}"

# Remove old image if exists
[ -f "$IMAGE_PATH" ] && rm "$IMAGE_PATH"

# mksquashfs with zstd compression
mksquashfs "$SITE_ROOT" "$IMAGE_PATH" -comp zstd -Xcompression-level 22 -all-root -no-progress

# Update version file
echo "$LATEST_VERSION" > "$VERSION_FILE"

# Cleanup
rm -rf "$TEMP_DIR"

echo -e "${GREEN}Success! IT Tools packaged into $IMAGE_PATH ($LATEST_VERSION)${NC}"