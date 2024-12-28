#!/bin/bash
#
# Script for interactive configuration of WB-MIO (or similar Modbus devices) via TCP and Modbus RTU.
# It performs the following steps:
#   1) Stops the wb-mqtt-serial service.
#   2) Launches socat to create a virtual serial port (PTY).
#   3) Checks the current Modbus address and speed registers.
#   4) Offers an interactive prompt to change the speed, validating user input.
#   5) Writes the new speed value and (optionally) reboots the device.
#   6) Stops socat and restarts wb-mqtt-serial.
#
# Requirements:
#   - Utilities: modbus_client, socat
#   - Sufficient privileges (root or sudo)
#
# Example usage:
#   chmod +x wb-mio-change-speed.sh
#   ./wb-mio-change-speed.sh

######################################
# PARAMETERS
######################################

# Network parameters for socat
IP_ADDRESS="10.10.100.7"
TCP_PORT="20108"

# Virtual serial port (PTY) that socat will create
DEV_PORT="/dev/ttyRS485-6"

# Current device settings for connecting to WB-MIO
CURRENT_BAUD=9600          # Current speed (e.g., 9600 or 115200)
CURRENT_PARITY="none"      # Parity: none / odd / even
CURRENT_STOPBITS=1         # Number of stop bits: 1 or 2
CURRENT_ADDR=139           # Current Modbus address

# WB-MIO Modbus registers
REG_SPEED=110              # Register for speed (baud / 100)
REG_ADDR=128               # Register for the device address
REG_REBOOT=120             # Register for rebooting the device

# An associative array mapping human-readable speeds to codes (baud / 100)
declare -A SPEED_MAP=(
  [1200]=12
  [2400]=24
  [4800]=48
  [9600]=96
  [19200]=192
  [38400]=384
  [57600]=576
  [115200]=1152
)

######################################
# SERVICE CONTROL FUNCTIONS
######################################

stop_wb_mqtt_serial() {
  echo "[INFO] Stopping the wb-mqtt-serial service..."
  systemctl stop wb-mqtt-serial

  # Status check
  if systemctl is-active wb-mqtt-serial --quiet; then
    echo "[WARNING] The wb-mqtt-serial service is still active!"
  else
    echo "[INFO] The wb-mqtt-serial service has been stopped."
  fi
}

start_wb_mqtt_serial() {
  echo "[INFO] Starting the wb-mqtt-serial service..."
  systemctl start wb-mqtt-serial

  if systemctl is-active wb-mqtt-serial --quiet; then
    echo "[INFO] The wb-mqtt-serial service started successfully."
  else
    echo "[ERROR] Failed to start the wb-mqtt-serial service!"
  fi
}

start_socat() {
  echo "[INFO] Launching socat: TCP=$IP_ADDRESS:$TCP_PORT -> $DEV_PORT"

  # Start socat with parameters derived from variables
  socat -d -d -d -x \
    PTY,raw,b${CURRENT_BAUD},parenb=0,cstopb=${CURRENT_STOPBITS},cs8,link="${DEV_PORT}" \
    tcp:"${IP_ADDRESS}":"${TCP_PORT}" &
  SOCAT_PID=$!

  # Give socat time to create the PTY
  sleep 2

  # Check if the socat process is still running
  if ! kill -0 "$SOCAT_PID" 2>/dev/null; then
    echo "[ERROR] Socat failed to start or exited immediately!"
    return 1
  fi

  echo "[INFO] Socat started (PID $SOCAT_PID)."
  return 0
}

stop_socat() {
  echo "[INFO] Stopping socat (PID=$SOCAT_PID)..."
  kill "$SOCAT_PID" 2>/dev/null
  wait "$SOCAT_PID" 2>/dev/null
  echo "[INFO] Socat has been stopped."
}

######################################
# MODBUS REGISTER FUNCTIONS
######################################

read_register() {
  local reg=$1
  local value

  value=$(modbus_client \
    -m rtu \
    -b "$CURRENT_BAUD" \
    -p "$CURRENT_PARITY" \
    -s "$CURRENT_STOPBITS" \
    "$DEV_PORT" \
    -a "$CURRENT_ADDR" \
    -t 0x03 \
    -r "$reg" 2>/dev/null | \
    awk -F'Data:' '/Data:/ {print $2}')

  echo "$value"
}

write_register() {
  local reg=$1
  local val=$2

  modbus_client \
    -m rtu \
    -b "$CURRENT_BAUD" \
    -p "$CURRENT_PARITY" \
    -s "$CURRENT_STOPBITS" \
    "$DEV_PORT" \
    -a "$CURRENT_ADDR" \
    -t 0x06 \
    -r "$reg" "$val"
}

check_device_addr() {
  local val_dec

  val_dec=$(read_register "$REG_ADDR")

  if [[ -z "$val_dec" ]]; then
    echo "[ERROR] Failed to read register $REG_ADDR (device address)."
    return 1
  fi

  # Convert to decimal if necessary
  val_dec=$(printf "%d\n" "$val_dec")

  echo "[INFO] Current device address (from reg.128): $val_dec"
  if [[ "$val_dec" -eq "$CURRENT_ADDR" ]]; then
    return 0
  else
    echo "[WARNING] The address in register 128 ($val_dec) does NOT match the expected ($CURRENT_ADDR)!"
    return 2
  fi
}

get_device_speed() {
  local val_dec

  val_dec=$(read_register "$REG_SPEED")

  if [[ -z "$val_dec" ]]; then
    echo "[ERROR] Failed to read the speed register ($REG_SPEED)."
    return 1
  fi

  # The device stores speed as (baud / 100)
  val_dec=$(printf "%d\n" "$val_dec")
  local baud=$((val_dec * 100))
  echo "$baud"
  return 0
}

set_device_speed() {
  local new_baud_code=$1
  echo "[INFO] Setting the new speed (code $new_baud_code) to register $REG_SPEED..."
  write_register "$REG_SPEED" "$new_baud_code"
}

reboot_device() {
  echo "[INFO] Sending reboot command to register $REG_REBOOT..."
  write_register "$REG_REBOOT" "1"
}

######################################
# MAIN SCRIPT LOGIC
######################################

# 1. Stop wb-mqtt-serial
stop_wb_mqtt_serial
echo "==========================================================="

# 2. Start socat
if ! start_socat ; then
  echo "[ERROR] Failed to start socat. Exiting."
  echo "==========================================================="
  start_wb_mqtt_serial
  exit 1
fi
echo "==========================================================="

# 3. Check the Modbus address
if ! check_device_addr ; then
  echo "[ERROR] The device address does not match or cannot be read. Exiting."
  echo "==========================================================="
  stop_socat
  start_wb_mqtt_serial
  exit 1
fi
echo "[INFO] The WB-MIO address is confirmed."
echo "==========================================================="

# 4. Read the current speed
CURRENT_DEVICE_SPEED=$(get_device_speed)
if [[ -z "$CURRENT_DEVICE_SPEED" ]]; then
  echo "[ERROR] Failed to read the current speed. Exiting."
  echo "==========================================================="
  stop_socat
  start_wb_mqtt_serial
  exit 1
fi
echo "[INFO] The current device speed is: $CURRENT_DEVICE_SPEED baud."
echo "==========================================================="

# 5. Ask if we want to change the speed
read -r -p "Do you want to change the speed? [y/N] " ans
ans="${ans,,}"  # Convert to lowercase
if [[ "$ans" =~ ^(y|yes)$ ]]; then
  echo "[INFO] Available speeds: ${!SPEED_MAP[@]}"
  read -r -p "Enter the desired speed (from the list above): " NEW_SPEED_INPUT

  # Validate the chosen speed
  if [[ -z "${SPEED_MAP[$NEW_SPEED_INPUT]}" ]]; then
    echo "[ERROR] Invalid speed: $NEW_SPEED_INPUT"
    echo "==========================================================="
    stop_socat
    start_wb_mqtt_serial
    exit 2
  fi

  NEW_SPEED_CODE=${SPEED_MAP[$NEW_SPEED_INPUT]}
  echo "[INFO] Selected speed: $NEW_SPEED_INPUT baud (code $NEW_SPEED_CODE)."

  # Apply the new speed
  set_device_speed "$NEW_SPEED_CODE"

  # Ask about reboot
  read -r -p "Reboot the device (to apply settings)? [y/N] " reboot_ans
  reboot_ans="${reboot_ans,,}"
  if [[ "$reboot_ans" =~ ^(y|yes)$ ]]; then
    reboot_device
    echo "[INFO] Reboot command sent. The device will restart and switch to the new speed."
  else
    echo "[INFO] Reboot not performed. The device may have already applied the new speed."
  fi

  echo "[INFO] After changing the speed, the old settings may no longer work."
  echo "[INFO] To continue at the new speed, restart the script with the updated CURRENT_BAUD."
else
  echo "[INFO] Keeping the current device speed: $CURRENT_DEVICE_SPEED baud."
fi

echo "==========================================================="
echo "[INFO] Finishing up: stopping socat and restarting wb-mqtt-serial..."

# 6. Stop socat
stop_socat

# 7. Restart wb-mqtt-serial
start_wb_mqtt_serial

echo "[INFO] Script execution completed."
exit 0
