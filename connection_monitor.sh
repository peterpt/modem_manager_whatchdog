#!/bin/sh

# --- Universal Cellular Connection Watchdog ---
# Version: 9.0 - "The Protocol-Aware" Edition. Now verifies that ModemManager is installed and in use before running.
# This script automatically detects modem details and recovers from specific failures for ModemManager-based setups.

# --- Configuration ---
LOG_TAG="CellularWatchdog"
PING_HOST="8.8.8.8"      # A reliable IP to test raw connectivity
PING_COUNT=4
NORMAL_SLEEP_INTERVAL=60   # Seconds to wait when connection is good.
LONG_SLEEP_INTERVAL=300  # 5 minutes. Seconds to wait when in a hard-fail state.
REAPPEAR_TIMEOUT=120

# --- Auto-Detected & State Variables ---
LOGICAL_INTERFACE=""
MODEM_VID_PID=""
AT_PORT=""
LAST_ACTION="" # This variable will track the last major recovery action.

# --- Helper Functions ---

detect_modem_details() {
    logger -t "$LOG_TAG" "Attempting to auto-detect modem details..."

    # --- NEW: Pre-flight checks to ensure this is a ModemManager system ---
    logger -t "$LOG_TAG" "Performing pre-flight checks..."
    if ! opkg list-installed | grep -q "modemmanager"; then
        logger -t "$LOG_TAG" -p daemon.crit "PRE-FLIGHT CHECK FAILED: The 'modemmanager' package is not installed. This script is for ModemManager setups only. Exiting."
        return 1
    fi
    if ! uci show network | grep -q "proto='modemmanager'"; then
        logger -t "$LOG_TAG" -p daemon.crit "PRE-FLIGHT CHECK FAILED: No network interface is configured with 'proto=modemmanager'. Exiting."
        return 1
    fi
    logger -t "$LOG_TAG" "Pre-flight checks passed. This is a ModemManager system."
    # --- End of Pre-flight checks ---

    local MODEM_INFO_FILE; MODEM_INFO_FILE=$(mktemp /tmp/modem_info.XXXXXX); trap 'rm -f "$MODEM_INFO_FILE"' EXIT
    local detection_attempts=0; local MODEM_INDEX; MODEM_INDEX=$(mmcli -L | sed -n 's/.*\/Modem\/\([0-9]\+\).*/\1/p' | head -n 1)
    if [ -z "$MODEM_INDEX" ]; then logger -t "$LOG_TAG" -p daemon.err "DETECTION FAILED: No modem found by ModemManager."; return 1; fi
    logger -t "$LOG_TAG" "Found modem at index: $MODEM_INDEX. Waiting for it to be fully populated..."
    while [ "$detection_attempts" -lt 15 ]; do
        mmcli -m "$MODEM_INDEX" > "$MODEM_INFO_FILE"
        if [ $? -eq 0 ] && grep -q "(at)" "$MODEM_INFO_FILE" && grep -q -w "System" "$MODEM_INFO_FILE"; then
            logger -t "$LOG_TAG" "Modem at index $MODEM_INDEX is fully populated."; break
        fi
        detection_attempts=$((detection_attempts + 1)); sleep 2
    done
    if ! [ -s "$MODEM_INFO_FILE" ] || ! grep -q "(at)" "$MODEM_INFO_FILE"; then
        logger -t "$LOG_TAG" -p daemon.err "DETECTION FAILED: Modem never populated its details."; return 1
    fi
    AT_PORT=$(grep '(at)' "$MODEM_INFO_FILE" | head -n 1 | awk '{print $2}'); AT_PORT="/dev/${AT_PORT}"
    if [ ! -c "$AT_PORT" ]; then logger -t "$LOG_TAG" -p daemon.err "DETECTION FAILED: AT port '$AT_PORT' is not a valid device."; return 1; fi
    local SYSFS_PATH; SYSFS_PATH=$(grep -w "System" "$MODEM_INFO_FILE" | awk '{print $4}')
    if [ ! -d "$SYSFS_PATH" ]; then logger -t "$LOG_TAG" -p daemon.err "DETECTION FAILED: sysfs path '$SYSFS_PATH' not found."; return 1; fi
    local ID_VENDOR; local ID_PRODUCT; ID_VENDOR=$(cat "$SYSFS_PATH/idVendor"); ID_PRODUCT=$(cat "$SYSFS_PATH/idProduct")
    MODEM_VID_PID="${ID_VENDOR}:${ID_PRODUCT}"
    if [ -z "$MODEM_VID_PID" ] || [ "$MODEM_VID_PID" = ":" ]; then logger -t "$LOG_TAG" -p daemon.err "DETECTION FAILED: Could not read VID:PID."; return 1; fi
    LOGICAL_INTERFACE=$(uci show network | grep "proto='modemmanager'" | head -n 1 | cut -d'.' -f2)
    if [ -z "$LOGICAL_INTERFACE" ]; then logger -t "$LOG_TAG" -p daemon.err "DETECTION FAILED: No ModemManager interface in UCI config."; return 1; fi
    logger -t "$LOG_TAG" -p daemon.notice "=== Modem Auto-Detection Complete ==="
    logger -t "$LOG_TAG" "Logical Interface: $LOGICAL_INTERFACE"; logger -t "$LOG_TAG" "Modem VID:PID:     $MODEM_VID_PID"; logger -t "$LOG_TAG" "AT Command Port:   $AT_PORT"
    logger -t "$LOG_TAG" "====================================="
    return 0
}

perform_full_recovery() {
    logger -t "$LOG_TAG" -p daemon.warn "=== Starting Full Modem Recovery ==="; service modemmanager stop; sleep 5
    echo -e "AT+CFUN=1,1\r" > "$AT_PORT"
    logger -t "$LOG_TAG" "Waiting up to $REAPPEAR_TIMEOUT seconds for modem ($MODEM_VID_PID) to reappear..."
    local wait_time=0; local modem_reappeared=false
    while [ "$wait_time" -lt "$REAPPEAR_TIMEOUT" ]; do
        if lsusb -d "$MODEM_VID_PID" >/dev/null 2>&1; then
            logger -t "$LOG_TAG" -p daemon.notice "SUCCESS: Modem has reappeared."; modem_reappeared=true; break
        fi
        sleep 5; wait_time=$((wait_time + 5))
    done
    if ! $modem_reappeared; then logger -t "$LOG_TAG" -p daemon.err "FATAL: Modem did not reappear."; LAST_ACTION="FATAL_HW"; return 1; fi
    service modemmanager start; logger -t "$LOG_TAG" "Waiting 45 seconds for ModemManager..."; sleep 45
    logger -t "$LOG_TAG" "Bringing up interface '$LOGICAL_INTERFACE'..."; ifup "$LOGICAL_INTERFACE"
    logger -t "$LOG_TAG" "=== Full Modem Recovery Attempt Finished ==="
}


# --- Main Script Execution ---
if ! detect_modem_details; then
    logger -t "$LOG_TAG" -p daemon.crit "Initial modem detection failed. Watchdog cannot run."; exit 1
fi
logger -t "$LOG_TAG" "Watchdog started. Monitoring interface '$LOGICAL_INTERFACE'."

# --- Main Monitoring Loop ---
while true; do
    if ping -c "$PING_COUNT" -W 5 "$PING_HOST" >/dev/null 2>&1; then
        if [ -n "$LAST_ACTION" ]; then
            logger -t "$LOG_TAG" -p daemon.notice "Connection restored. Returning to normal monitoring."
            LAST_ACTION=""
        fi
        sleep "$NORMAL_SLEEP_INTERVAL"
    else
        logger -t "$LOG_TAG" -p daemon.warn "Ping failed. Analyzing modem state..."
        local CURRENT_MODEM_INDEX; CURRENT_MODEM_INDEX=$(mmcli -L | sed -n 's/.*\/Modem\/\([0-9]\+\).*/\1/p' | head -n 1)
        if [ -z "$CURRENT_MODEM_INDEX" ]; then
            logger -t "$LOG_TAG" -p daemon.err "Modem not found. Assuming hardware glitch."; perform_full_recovery
            LAST_ACTION="RECOVERY"
            sleep "$NORMAL_SLEEP_INTERVAL"
        else
            local MODEM_STATUS; MODEM_STATUS=$(mmcli -m "$CURRENT_MODEM_INDEX")
            if echo "$MODEM_STATUS" | grep -q "reason: sim-missing"; then
                if [ "$LAST_ACTION" = "RECOVERY_SIM_MISSING" ]; then
                    logger -t "$LOG_TAG" -p daemon.warn "CRITICAL: 'sim-missing' persists after recovery. This requires physical action. Entering long-term monitoring mode."
                    sleep "$LONG_SLEEP_INTERVAL"
                else
                    logger -t "$LOG_TAG" -p daemon.err "DIAGNOSIS: Modem reports 'sim-missing'. Starting full recovery."
                    perform_full_recovery
                    LAST_ACTION="RECOVERY_SIM_MISSING"
                    sleep "$NORMAL_SLEEP_INTERVAL"
                fi
            else
                logger -t "$LOG_TAG" -p daemon.notice "DIAGNOSIS: Standard drop. Attempting soft restart of '$LOGICAL_INTERFACE'."; ifdown "$LOGICAL_INTERFACE" && sleep 10 && ifup "$LOGICAL_INTERFACE"
                LAST_ACTION="SOFT_RESET"
                sleep "$NORMAL_SLEEP_INTERVAL"
            fi
        fi
    fi
done
    

    
