#!/bin/zsh

# Script to automate SmartThings Edge driver deployment for ONVIF Video Camera V2.1
# - Packages the driver from the current directory
# - Assigns it to "dMacs ONVIF Doorbell Channel" (f7aef30d-dbb2-451a-9215-c9b7d6f8d413)
# - Installs it on "FRIDGE" hub (83404a4e-b2af-469e-b4f2-3363cb76723a)
# - Starts logcat, selects hub 3 (FRIDGE), and driver 20 (ONVIF Video Camera V2.1)

# Constants
DRIVER_NAME="ONVIF Video Camera V2.1"
DRIVER_ID="3f8372e4-5dc4-48d2-bdd4-2a6780ddf076"
CHANNEL_ID="f7aef30d-dbb2-451a-9215-c9b7d6f8d413"
HUB_ID="83404a4e-b2af-469e-b4f2-3363cb76723a"
HUB_LABEL="FRIDGE"

# Ensure we're in the correct directory
if [[ $(basename $PWD) != "hubpackage" ]]; then
    echo "Error: Please run this script from the 'hubpackage' directory."
    exit 1
fi

# Function to check command success
check_status() {
    if [[ $? -ne 0 ]]; then
        echo "Error: $1 failed. Exiting."
        exit 1
    fi
}

echo "Starting deployment of $DRIVER_NAME..."

# Step 1: Package the driver
echo "Packaging driver..."
smartthings edge:drivers:package
check_status "Packaging"

# Step 2: Assign driver to channel
echo "Assigning driver $DRIVER_ID to channel $CHANNEL_ID..."
# Select 1 for channel, 2 for driver
( echo "1"; sleep 3; echo "2" ) | smartthings edge:channels:assign
check_status "Channel assignment"

# Step 3: Install driver on FRIDGE hub
echo "Installing driver $DRIVER_ID on $HUB_LABEL hub ($HUB_ID)..."
# Select 3 for FRIDGE hub, 1 for channel, 2 for driver
( echo "3"; sleep 3; echo "1"; sleep 3; echo "2"; sleep 3; ) | smartthings edge:drivers:install
check_status "Installation"

# Step 4: Start logcat for FRIDGE hub and select driver
echo "Starting logcat for $HUB_LABEL hub and selecting driver $DRIVER_NAME..."
# Select 3 for FRIDGE hub, 20 for driver, with --restart to clear previous logs
( echo "3"; sleep 3; echo "20" ) | smartthings edge:drivers:logcat

echo "Deployment complete! Logcat is running for $HUB_LABEL hub with $DRIVER_NAME."