#!/bin/bash
set -e

DEST_DIR=/opt/azurehpc/tools
mkdir -p $DEST_DIR

# Download the file
wget https://raw.githubusercontent.com/microsoft/lis-test/master/WS2012R2/lisa/tools/KVP/kvp_client.c

# ✅ Fix outdated code

# Fix missing return type for main()
sed -i 's/^main(/int main(/' kvp_client.c

# Disable kvp_key_exists usage (prevents compile error)
sed -i 's/kvp_key_exists([^)]*)/0/g' kvp_client.c

# Move and compile
mv ./kvp_client.c $DEST_DIR

gcc $DEST_DIR/kvp_client.c -o $DEST_DIR/kvp_client