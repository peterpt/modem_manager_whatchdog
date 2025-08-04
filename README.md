# Universal Cellular Watchdog for OpenWrt with ModemManager


## Startup script image

![Alt text](https://github.com/peterpt/modem_manager_whatchdog/blob/main/cewlularwatchdog.jpg)

## Description
This script is an intelligent, resilient watchdog for maintaining a stable cellular connection on OpenWrt routers using ModemManager. It automatically detects modem hardware, monitors the connection, and performs a series of escalating recovery actions—from a simple interface restart to a full firmware-level modem reset—to handle connection drops and specific hardware glitches like the "sim-missing" error.

It was designed to be a "fire and forget" solution that requires no manual hardware configuration and is robust enough to handle permanent physical failures gracefully without quitting.

## Key Features

- **Protocol-Aware:** Performs "pre-flight checks" to ensure `modemmanager` is installed and configured on an interface before running. It will not run on unsupported systems (e.g., QMI or NCM native setups).
- **Universal Auto-Detection:** Automatically detects the modem's Vendor/Product ID, AT command port, and logical interface name at startup.
- **Intelligent Triage:** Differentiates between simple connection drops, critical `sim-missing` errors, and unrecoverable hardware failures.
- **Patient & Resilient:** If a critical error (like a missing SIM) persists after a full recovery attempt, the script does not exit or enter a fast loop. Instead, it transitions to a long-term, low-intensity monitoring mode, patiently waiting for the physical issue to be resolved by the user.
- **Robust Recovery:** Employs a proven "Golden Recipe" of a firmware-level reset (`AT+CFUN=1,1`) followed by a ModemManager service restart to recover from otherwise fatal modem glitches.
- **Efficient & Stable:** Built with robust, event-driven logic and optimized text-parsing to be reliable and lightweight. It uses a temporary file for efficient analysis, running complex commands only once per check.
- **Detailed Logging:** Provides clear, tagged logs via `logread` for easy troubleshooting, using the tag `CellularWatchdog`.

## How It Works

The script operates in two main phases: an initial auto-detection phase and a continuous monitoring loop.

### Phase 1: Startup & Auto-Detection (`detect_modem_details` function)

When the script first starts, it runs this function to learn about the hardware it's supposed to manage.

1.  **Pre-flight Check:** It first verifies that the `modemmanager` package is installed and that at least one network interface is configured with `proto='modemmanager'`. If not, it exits gracefully.
2.  **Find Modem Index:** It asks ModemManager (`mmcli -L`) for a list of available modems and extracts the index of the first one (e.g., `0`).
3.  **Create Temporary Workspace:** It creates a secure, unique temporary file in `/tmp` to store the modem's detailed information. This is done for efficiency, so the `mmcli -m` command is only run once per detection cycle.
4.  **"Intelligent Wait" for Full Initialization:** The script enters a loop, repeatedly checking the modem's status. It only proceeds when it confirms that ModemManager has fully populated all the necessary details (specifically, the `(at)` port and `System` information), preventing race conditions during startup.
5.  **Parse "Ground Truth" Data:** Once the modem is fully ready, the script parses the temporary file to set its operational variables:
    -   **`AT_PORT`:** It robustly finds the line containing `(at)` and extracts the correct device name (e.g., `ttyUSB2`), then constructs the full path (`/dev/ttyUSB2`).
    -   **`SYSFS_PATH`:** It finds the `System` line and extracts the device's system path.
    -   **`MODEM_VID_PID`:** Using the `SYSFS_PATH`, it reads the `idVendor` and `idProduct` files to get the modem's true hardware ID (e.g., `2c7c:0125`), which is used for hardware-level checks.
    -   **`LOGICAL_INTERFACE`:** It inspects the OpenWrt UCI configuration (`uci show network`) to find the name of the network interface that uses the `modemmanager` protocol (e.g., `4G_Modem`, `wan`).

### Phase 2: The Main Monitoring Loop (`while true`)

After the detection phase succeeds, the script enters its main infinite loop, which is the "heartbeat" of the watchdog.

1.  **Health Check:** It pings a reliable IP address (`8.8.8.8`).
2.  **If Ping Succeeds:** The connection is healthy. The script clears any previous failure flags and sleeps for the normal interval (e.g., 60 seconds).
3.  **If Ping Fails:** The script logs the failure and begins its diagnostic triage:
    -   It first checks the modem status via `mmcli`.
    -   **If `sim-missing` error:** The script checks if it has *already* tried a full recovery for this specific error.
        -   If it has, it assumes the problem is physical. It logs a critical message and enters a **long-term monitoring mode**, sleeping for a much longer interval (e.g., 5 minutes). It will not attempt another disruptive recovery until the `sim-missing` state changes.
        -   If this is the first time seeing the error, it attempts the `perform_full_recovery` function and sets a flag to remember this action.
    -   **For any other error:** The script assumes a "soft failure." It attempts the simplest fix: restarting the logical interface (`ifdown` and `ifup`).

### The Full Recovery Protocol (The `perform_full_recovery` function)

This function is the script's most powerful tool, used only for the most severe failures.

1.  **Stop Service:** It stops ModemManager (`service modemmanager stop`).
2.  **Hardware Firmware Reset:** It sends the `AT+CFUN=1,1` command directly to the detected AT port.
3.  **Intelligent Hardware Wait:** It polls `lsusb` every few seconds, waiting for the modem device to reappear on the USB bus.
4.  **Start Service:** Once the hardware is back, it starts ModemManager fresh (`service modemmanager start`).
5.  **Wait for Initialization:** It waits a generous 45 seconds for ModemManager to initialize the newly reset modem.
6.  **Give "Green Light":** Finally, it runs `ifup` on the logical interface to command the modem to connect.

## Installation & Usage

This watchdog is designed to be run as a standard system service in OpenWrt.

1.  **Copy the Files:**
    -   Copy the main script, `connection_monitor.sh`, to `/usr/sbin/`.
    -   Copy the init script, `connection_monitor`, to the `/etc/init.d/` directory on your router.

2.  **Set Permissions:** Connect to your router via SSH and make both files executable:
    ```bash
    chmod +x /usr/sbin/connection_monitor.sh
    chmod +x /etc/init.d/connection_monitor
    ```
3.  **Enable the Service:** Enable the service to make it start automatically every time your router boots.
    ```bash
    /etc/init.d/connection_monitor enable
    ```
4.  **Start the Service:** You can start the service for the first time without needing to reboot:
    ```bash
    /etc/init.d/connection_monitor start
    ```
5.  **Verify It's Running:** Watch its log output to see the auto-detection phase complete successfully. The script uses the log tag `CellularWatchdog` by default.
    ```bash
    logread -f -e CellularWatchdog
    ```

### Managing the Service

You can now manage the watchdog like any other system service:
-   **To stop the watchdog:** `/etc/init.d/connection_monitor stop`
-   **To restart the watchdog:** `/etc/init.d/connection_monitor restart`
-   **To disable it from starting on boot:** `/etc/init.d/connection_monitor disable`

## Configuration

The script is designed to be fully automatic, but you can tweak these variables at the top of `connection_monitor.sh` if needed:
-   `PING_HOST`: The IP address to ping for health checks. `8.8.8.8` is a reliable choice.
-   `NORMAL_SLEEP_INTERVAL`: The number of seconds to wait between health checks when the connection is good.
-   `LONG_SLEEP_INTERVAL`: The number of seconds to wait between checks when the script has detected a persistent physical problem (like a missing SIM).

## Authors & Acknowledgements

This script was developed and rigorously debugged in a collaborative effort:

-   **Peter (peterpt on GitHub)**: Lead Engineer, Testing, Real-World Diagnostics, and Logic Refinement
-   **Google's Gemini Pro Model**: Code Generation, Initial Logic, and Debugging Assistance

This project would have been impossible without the meticulous, step-by-step testing and insightful analysis provided by the lead engineer.

## License
This project is licensed under the MIT License.
