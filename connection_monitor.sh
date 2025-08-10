#!/bin/sh

# --- Universal Cellular Connection Watchdog & Failover Manager ---
# Version: 28.0 - "The Commander's Intent" Edition. The definitive professional version.
# This script operates as a complete, stateful failover manager and hardware medic
# based on a clear, user-defined operational doctrine for maximum unattended reliability.

# --- Configuration ---
LOG_TAG="CellularWatchdog"
PING_HOST="8.8.8.8"
PING_COUNT=4
NORMAL_SLEEP_INTERVAL=60  # The core 1-minute check interval
REAPPEAR_TIMEOUT=120
INITIAL_CONNECT_TIMEOUT=180 # 3 minutes
FLAG_FILE="/tmp/cellular_watchdog.boot.flag"
MAX_SOFT_RESETS=2
MAX_FULL_RECOVERIES=2
HIBERNATION_INTERVAL=3600 # 1 hour

# --- Tool Path Variables ---
# (Populated by initialize_tool_paths)

# --- Auto-Detected & State Variables ---
LOGICAL_INTERFACE=""
PHYSICAL_DEVICE=""
PRIMARY_WAN_IFACE=""
PRIMARY_WAN_PHYSICAL_DEVICE=""
MODEM_INDEX=""
FULL_RECOVERY_COUNT=0
SOFT_RESET_COUNT=0

# --- Helper Functions ---
find_tool() { local tool_name="$1"; for path in /bin /sbin /usr/bin /usr/sbin; do if [ -x "${path}/${tool_name}" ]; then echo "${path}/${tool_name}"; return 0; fi; done; command -v "$tool_name"; }
get_physical_device() { local logical_iface="$1"; ubus call network.interface."$logical_iface" status 2>/dev/null | "$GREP_CMD" -o '"l3_device": *"[^"]*"' | "$CUT_CMD" -d'"' -f4; }
initialize_tool_paths() {
    logger -t "$LOG_TAG" "Initializing tool paths..."; MMCLI_CMD=$(find_tool mmcli); LSUSB_CMD=$(find_tool lsusb); AWK_CMD=$(find_tool awk); GREP_CMD=$(find_tool grep); SED_CMD=$(find_tool sed); HEAD_CMD=$(find_tool head); IP_CMD=$(find_tool ip); PING_CMD=$(find_tool ping); SERVICE_CMD=$(find_tool service); IFUP_CMD=$(find_tool ifup); IFDOWN_CMD=$(find_tool ifdown); TOUCH_CMD=$(find_tool touch); CUT_CMD=$(find_tool cut); CAT_CMD=$(find_tool cat); MKTEMP_CMD=$(find_tool mktemp); ECHO_CMD=$(find_tool echo); RM_CMD=$(find_tool rm); SLEEP_CMD=$(find_tool sleep); UCI_CMD=$(find_tool uci)
    for cmd_var in MMCLI_CMD LSUSB_CMD AWK_CMD GREP_CMD SED_CMD HEAD_CMD PING_CMD SERVICE_CMD IFUP_CMD IFDOWN_CMD TOUCH_CMD CUT_CMD CAT_CMD MKTEMP_CMD ECHO_CMD RM_CMD SLEEP_CMD UCI_CMD IP_CMD; do
        eval "local cmd_path=\$$cmd_var"; if [ -z "$cmd_path" ]; then local tool_name; tool_name=$("$ECHO_CMD" "$cmd_var" | "$SED_CMD" 's/_CMD$//' | tr 'A-Z' 'a-z'); logger -t "$LOG_TAG" -p daemon.crit "DEPENDENCY ERROR: Could not find required tool '$tool_name'. Exiting."; return 1; fi
    done; logger -t "$LOG_TAG" "All tool paths initialized successfully."; return 0
}
detect_interfaces() {
    # This function just gets names. It doesn't require a connection.
    LOGICAL_INTERFACE=$("$UCI_CMD" show network | "$GREP_CMD" "proto='modemmanager'" | "$HEAD_CMD" -n 1 | "$CUT_CMD" -d'.' -f2)
    PRIMARY_WAN_IFACE=""
    local wan_zone_networks; wan_zone_networks=$("$UCI_CMD" get firewall.@zone[1].network 2>/dev/null)
    for iface in $wan_zone_networks; do
        if [ "$iface" != "$LOGICAL_INTERFACE" ]; then
            PRIMARY_WAN_IFACE="$iface"
            break
        fi
    done
    if [ -z "$LOGICAL_INTERFACE" ]; then return 1; else return 0; fi
}
get_modem_details_for_recovery() {
    # This special function is called only when a recovery is needed.
    MODEM_INDEX=$("$MMCLI_CMD" -L | "$GREP_CMD" -o '/Modem/[0-9]*' | "$AWK_CMD" -F'/' '{print $3}' | "$HEAD_CMD" -n 1)
    if [ -z "$MODEM_INDEX" ]; then return 1; fi

    local MODEM_INFO_FILE; MODEM_INFO_FILE=$("$MKTEMP_CMD" /tmp/recovery_info.XXXXXX); trap ''$RM_CMD' -f "$MODEM_INFO_FILE"' EXIT
    "$MMCLI_CMD" -m "$MODEM_INDEX" > "$MODEM_INFO_FILE"
    if ! [ -s "$MODEM_INFO_FILE" ]; then return 1; fi

    AT_PORT=$("$GREP_CMD" '(at)' "$MODEM_INFO_FILE" | "$HEAD_CMD" -n 1 | "$AWK_CMD" '{print $2}'); AT_PORT="/dev/${AT_PORT}"
    local SYSFS_PATH; SYSFS_PATH=$("$GREP_CMD" -w "System" "$MODEM_INFO_FILE" | "$AWK_CMD" '{print $4}')
    if [ ! -d "$SYSFS_PATH" ]; then return 1; fi
    local ID_VENDOR; local ID_PRODUCT; ID_VENDOR=$("$CAT_CMD" "$SYSFS_PATH/idVendor"); ID_PRODUCT=$("$CAT_CMD" "$SYSFS_PATH/idProduct"); MODEM_VID_PID="${ID_VENDOR}:${ID_PRODUCT}"
    return 0
}
perform_full_recovery() {
    if ! get_modem_details_for_recovery; then logger -t "$LOG_TAG" -p daemon.err "Full Recovery Fail: Cannot get modem details for reset."; FULL_RECOVERY_COUNT=$((FULL_RECOVERY_COUNT+1)); return; fi
    logger -t "$LOG_TAG" -p daemon.warn "=== Starting Full Modem Recovery (Attempt #$((FULL_RECOVERY_COUNT + 1)) of $MAX_FULL_RECOVERIES) ==="; "$SERVICE_CMD" modemmanager stop; "$SLEEP_CMD" 5; "$ECHO_CMD" -e "AT+CFUN=1,1\r" > "$AT_PORT";
    local wait_time=0; local modem_reappeared=false; while [ "$wait_time" -lt "$REAPPEAR_TIMEOUT" ]; do if "$LSUSB_CMD" -d "$MODEM_VID_PID" >/dev/null 2>/dev/null; then modem_reappeared=true; break; fi; "$SLEEP_CMD" 5; wait_time=$((wait_time + 5)); done
    if ! $modem_reappeared; then logger -t "$LOG_TAG" -p daemon.err "FATAL: Modem did not reappear after full reset."; FULL_RECOVERY_COUNT=$((FULL_RECOVERY_COUNT + 1)); return; fi
    "$SERVICE_CMD" modemmanager start; "$SLEEP_CMD" 45; "$IFUP_CMD" "$LOGICAL_INTERFACE";
}

# --- Main Script Execution ---
if ! initialize_tool_paths; then exit 1; fi
logger -t "$LOG_TAG" "Autonomous Failover Engine started."

# --- Main Monitoring Loop ---
while true; do
    # --- Always detect basic interface names first ---
    if ! detect_interfaces; then
        logger -t "$LOG_TAG" -p daemon.warn "Could not detect configured interfaces. Waiting..."
    else
        # --- The Boot Gate: Patiently wait on first run ---
        if [ ! -f "$FLAG_FILE" ]; then
            logger -t "$LOG_TAD" -p daemon.notice "First run since boot. Patiently monitoring for up to $INITIAL_CONNECT_TIMEOUT seconds..."
            "$TOUCH_CMD" "$FLAG_FILE"
            wait_init=0; initially_connected=false
            while [ "$wait_init" -lt "$INITIAL_CONNECT_TIMEOUT" ]; do
                PRIMARY_WAN_PHYSICAL_DEVICE=$(get_physical_device "$PRIMARY_WAN_IFACE")
                if [ -n "$PRIMARY_WAN_IFACE" ] && "$IP_CMD" -4 addr show "$PRIMARY_WAN_PHYSICAL_DEVICE" 2>/dev/null | "$GREP_CMD" -q "inet"; then initially_connected=true; break; fi
                PHYSICAL_DEVICE=$(get_physical_device "$LOGICAL_INTERFACE")
                if "$IP_CMD" -4 addr show "$PHYSICAL_DEVICE" 2>/dev/null | "$GREP_CMD" -q "inet"; then initially_connected=true; break; fi
                "$SLEEP_CMD" 10; wait_init=$((wait_init + 10))
            done
            if $initially_connected; then logger -t "$LOG_TAG" "Initial connection detected. Proceeding with active monitoring."; else logger -t "$LOG_TAG" -p daemon.warn "Initial connection not detected within timeout. Watchdog will now take active measures."; fi
        fi

        # --- Active Monitoring State Machine ---
        PRIMARY_WAN_PHYSICAL_DEVICE=$(get_physical_device "$PRIMARY_WAN_IFACE")
        primary_is_up=false
        if [ -n "$PRIMARY_WAN_IFACE" ] && "$IP_CMD" -4 addr show "$PRIMARY_WAN_PHYSICAL_DEVICE" 2>/dev/null | "$GREP_CMD" -q "inet"; then
            primary_is_up=true
        fi

        if $primary_is_up; then
            logger -t "$LOG_TAG" "Primary WAN ('$PRIMARY_WAN_IFACE') is online. System stable. Resetting counters."
            FULL_RECOVERY_COUNT=0; SOFT_RESET_COUNT=0
            if ubus call network.interface."$LOGICAL_INTERFACE" status 2>/dev/null | "$GREP_CMD" -q '"up": true'; then
                logger -t "$LOG_TAG" -p daemon.notice "Deactivating backup modem ('$LOGICAL_INTERFACE')."
                "$IFDOWN_CMD" "$LOGICAL_INTERFACE"
            fi
        else
            # Primary WAN is down. Modem must be our connection.
            if [ -n "$PRIMARY_WAN_IFACE" ]; then logger -t "$LOG_TAG" -p daemon.warn "FAILOVER: Primary WAN is down. Managing backup modem."; fi
            
            PHYSICAL_DEVICE=$(get_physical_device "$LOGICAL_INTERFACE")
            if ! ("$IP_CMD" -4 addr show "$PHYSICAL_DEVICE" 2>/dev/null | "$GREP_CMD" -q "inet"); then
                # Modem is down. We must take action.
                logger -t "$LOG_TAG" -p daemon.warn "Modem interface has no IP. Starting recovery."
                if [ "$FULL_RECOVERY_COUNT" -ge "$MAX_FULL_RECOVERIES" ]; then
                    logger -t "$LOG_TAG" -p daemon.crit "CRITICAL: Maximum full recovery failures reached. Hibernating for $HIBERNATION_INTERVAL seconds..."
                    "$SLEEP_CMD" "$HIBERNATION_INTERVAL"
                    logger -t "$LOG_TAG" "Hibernation finished. Resetting counter and retrying."
                    FULL_RECOVERY_COUNT=0; SOFT_RESET_COUNT=0
                else
                    if [ "$SOFT_RESET_COUNT" -ge "$MAX_SOFT_RESETS" ]; then
                        perform_full_recovery
                        SOFT_RESET_COUNT=0 # Reset soft counter after escalating
                    else
                        logger -t "$LOG_TAG" -p daemon.notice "Attempting soft restart (Attempt #$((SOFT_RESET_COUNT + 1)) of $MAX_SOFT_RESETS).";
                        "$IFDOWN_CMD" "$LOGICAL_INTERFACE" && "$SLEEP_CMD" 10 && "$IFUP_CMD" "$LOGICAL_INTERFACE"
                        SOFT_RESET_COUNT=$((SOFT_RESET_COUNT + 1))
                    fi
                fi
            else
                # Modem is up and has an IP. Reset counters.
                logger -t "$LOG_TAG" "Modem is online with IP. Monitoring connection."
                FULL_RECOVERY_COUNT=0; SOFT_RESET_COUNT=0
            fi
        fi
    fi
    
    "$SLEEP_CMD" "$NORMAL_SLEEP_INTERVAL"
done
