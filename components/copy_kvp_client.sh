#!/bin/bash
set -e

DEST_DIR=/opt/azurehpc/tools
sudo mkdir -p $DEST_DIR

# Ensure gcc is available
sudo apt-get update
sudo apt-get install -y gcc

# Download source
wget https://raw.githubusercontent.com/microsoft/lis-test/master/WS2012R2/lisa/tools/KVP/kvp_client.c

# Fix outdated code

# Fix missing return type for main()
sed -i 's/^main(/int main(/' kvp_client.c

# Disable kvp_key_exists usage
sed -i 's/kvp_key_exists([^)]*)/0/g' kvp_client.c

# Move and compile
sudo mv kvp_client.c $DEST_DIR
sudo gcc $DEST_DIR/kvp_client.c -o $DEST_DIR/kvp_client
``