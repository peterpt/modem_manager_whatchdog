# Universal Cellular Watchdog for OpenWrt with ModemManager

This script is an intelligent watchdog for maintaining a stable cellular connection on OpenWrt routers using ModemManager. It automatically detects modem hardware, monitors the connection, and performs a series of escalating recovery actions—from a simple interface restart to a full firmware-level modem reset—to handle connection drops and specific hardware glitches like the "sim-missing" error.

It was designed to be a "fire and forget" solution that requires no manual hardware configuration.

## Key Features

- **Universal Auto-Detection:** Automatically detects the modem's Vendor/Product ID, AT command port, and logical interface name at startup.
- **Intelligent Triage:** Differentiates between simple connection drops (handled with a soft interface restart) and deep hardware/firmware failures (handled with a full recovery protocol).
- **Robust Recovery:** Employs a proven "Golden Recipe" of a firmware-level reset (`AT+CFUN=1,1`) followed by a ModemManager service restart to recover from otherwise fatal modem glitches.
- **Efficient & Stable:** Built with robust, event-driven logic and optimized text-parsing to be reliable and lightweight. It uses a temporary file for efficient analysis, running complex commands only once per check.
- **Detailed Logging:** Provides clear, tagged logs via `logread` for easy troubleshooting, using the tag `CellularWatchdog`.

## How It Works

The script operates in two main phases: an initial auto-detection phase and a continuous monitoring loop.

### Phase 1: Startup & Auto-Detection (The `detect_modem_details` function)

When the script first starts, it runs this function to learn about the hardware it's supposed to manage.

1.  **Find Modem Index:** It asks ModemManager (`mmcli -L`) for a list of available modems and extracts the index of the first one (e.g., `0`).
2.  **Create Temporary Workspace:** It creates a secure, unique temporary file in `/tmp` to store the modem's detailed information. This is done for efficiency, so the `mmcli -m` command is only run once per detection cycle.
3.  **"Intelligent Wait" for Full Initialization:** The script enters a loop, repeatedly checking the modem's status. It only proceeds when it confirms that ModemManager has fully populated all the necessary details (specifically, the `(at)` port and `System` information), preventing race conditions during startup.
4.  **Parse "Ground Truth" Data:** Once the modem is fully ready, the script parses the temporary file to set its operational variables:
    -   **`AT_PORT`:** It robustly finds the line containing `(at)` and extracts the correct device name (e.g., `ttyUSB2`), then constructs the full path (`/dev/ttyUSB2`).
    -   **`SYSFS_PATH`:** It finds the `System` line and extracts the device's system path.
    -   **`MODEM_VID_PID`:** Using the `SYSFS_PATH`, it reads the `idVendor` and `idProduct` files to get the modem's true hardware ID (e.g., `2c7c:0125`), which is used for hardware-level checks.
    -   **`LOGICAL_INTERFACE`:** It inspects the OpenWrt UCI configuration (`uci show network`) to find the name of the network interface that uses the `modemmanager` protocol (e.g., `4G_Modem`, `wan`).

If this detection phase fails, the script will exit, as it cannot operate without this critical information.

### Phase 2: The Main Monitoring Loop (`while true`)

After the detection phase succeeds, the script enters its main infinite loop, which is the "heartbeat" of the watchdog.

1.  **Health Check:** It pings a reliable IP address (`8.8.8.8`).
2.  **If Ping Succeeds:** The connection is healthy. The script does nothing and sleeps for the configured interval (e.g., 60 seconds).
3.  **If Ping Fails:** The script logs the failure and begins its diagnostic triage:
    -   It first checks if the modem is still visible to ModemManager. If not, it assumes a catastrophic hardware glitch and triggers the `perform_full_recovery` function.
    -   If the modem is visible, it checks its status.
        -   **`sim-missing` error:** If the modem reports this specific, known error, the script knows a simple reset won't work. It triggers the powerful `perform_full_recovery` function.
        -   **Any other error:** For all other types of failures (e.g., a temporary signal loss), the script attempts a "soft reset" by restarting the logical interface (`ifdown` and `ifup`). This is the least disruptive fix and is tried first for common issues.

### The Full Recovery Protocol (The `perform_full_recovery` function)

This function is the script's most powerful tool, used only for the severe failures diagnosed above. It executes the "Golden Recipe" we discovered through testing.

1.  **Stop Service:** It stops ModemManager (`service modemmanager stop`) to ensure a clean slate.
2.  **Hardware Firmware Reset:** It sends the `AT+CFUN=1,1` command directly to the detected AT port, forcing the modem's own firmware to perform a full reboot.
3.  **Intelligent Hardware Wait:** It polls `lsusb` every few seconds, waiting for the modem device to physically reappear on the USB bus. This is more reliable than a fixed sleep timer.
4.  **Start Service:** Once the hardware is back, it starts ModemManager fresh (`service modemmanager start`).
5.  **Wait for Initialization:** It waits a generous 45 seconds for ModemManager to find and initialize the newly reset modem.
6.  **Give "Green Light":** Finally, it runs `ifup` on the logical interface to command the newly ready modem to establish a data connection.

## Installation & Usage

1.  **Copy the Script:** Save the script's code to a file on your OpenWrt router, for example: `/root/cellular_watchdog.sh`.
2.  **Make it Executable:** Connect to your router via SSH and run:
    ```bash
    chmod +x /root/cellular_watchdog.sh
    ```
3.  **Test It (Recommended):** Run the script from the command line to ensure the auto-detection works correctly on your system.
    ```bash
    # Start the script in the background
    /root/cellular_watchdog.sh &

    # Watch its log output
    logread -f -e CellularWatchdog
    ```
    The script should print a successful "Modem Auto-Detection Complete" block and then begin its monitoring cycle.
4.  **Enable on Boot:** Once you are confident it works, make it start automatically.
    -   Navigate to `System -> Startup` in the LuCI web interface.
    -   Scroll down to the "Local Startup" text box.
    -   Add the following line **before** the `exit 0` line:
        ```
        /root/cellular_watchdog.sh &
        ```
    -   Save and apply. The script will now start automatically every time your router boots.

## Configuration

The script is designed to be fully automatic, but you can tweak these variables at the top of the file if needed:
-   `PING_HOST`: The IP address to ping for health checks. `8.8.8.8` is a reliable choice.
-   `PING_COUNT`: The number of pings to send.
-   `SLEEP_INTERVAL`: The number of seconds to wait between health checks when the connection is good.

## Authors & Acknowledgements

This script was developed and rigorously debugged in a collaborative effort:

-   **peterpt**: Lead Engineer, Testing, and Real-World Diagnostics
-   **Google's Gemini Pro Model**: Code Generation, Initial Logic, and Debugging Assistance

This project would have been impossible without the meticulous, step-by-step testing and insightful analysis provided by the lead engineer.

## License
This project is licensed under the MIT License.
