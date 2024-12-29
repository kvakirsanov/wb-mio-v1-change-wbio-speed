# Configuring WirenBoard WB-MIO-E v1 Device via Modbus Registers

## Problem Statement

When using **WirenBoard** devices—specifically the **WB-MIO-E v1** gateway—to interface with **WBIO** expansion modules such as **WBIO-DI-WD-14**, **WBIO-DO-R10R-4**, and others, you must ensure the **communication speed** on the WB-MIO-E for **WBIO bus** is correctly set. By **default**, the WB-MIO-E v1 operates at **9600** baud. 
If you wish to run at **any other speed**, you **must** explicitly **change** the **Modbus register** responsible for speed (register 110).

Failing to match the correct speed leads to  **No communication** with attached WBIO modules.

Hence, the **problem** is:  
1. The WB-MIO-E v1 WBIO bus speed defaults to 9600 but may need to be changed to a higher or lower baud rate (e.g., 115200).  
2. The only way to do this is by **writing** to Modbus registers (e.g., register 110 for speed).  
3. Some firmware revisions apply speed changes **only** after writing `1` to the reboot register (120).  

## Proposed Solution: An Interactive Bash Script

To address this, we provide a **Bash script** that:

1. **Stops** any service holding the RS-485 port (like `wb-mqtt-serial` on Wiren Board).  
2. **Creates** a TCP↔PTY bridge using `socat`.  
3. **Reads** and **writes** the **Modbus registers** (address, speed, reboot) on the WB-MIO-E via `modbus_client`.  
4. **Prompts** you interactively for the new speed, making it easy to switch away from the default 9600 if needed.

### Key Steps in the Script

1. **Stop `wb-mqtt-serial`**:  
   - Ensures no conflicts for the serial port.  
   - Allows `socat` to establish a clean connection.

2. **Launch `socat`**:  
   - Bridges a TCP connection (`IP_ADDRESS:TCP_PORT`) to a local virtual device (`DEV_PORT`).  
   - Essential if the WB-MIO-E is behind a network or RS-485→TCP converter.

3. **Check & Set Registers**:
   - **Register 128**: Modbus Address (verifies you are talking to the right MIO-E).  
   - **Register 110**: Speed (baud/100). By default 9600 → 96, but you can change to e.g. 1152 for 115200.  
   - **Register 120**: Reboot control (1 triggers a reboot if required to finalize speed changes).

4. **Interactive Prompt**:
   - Reads the current speed from register 110.  
   - Asks if you want to switch to a new baud rate.  
   - Validates your choice (e.g., 19200, 115200) and writes the correct code to the register.  
   - Optionally reboots the WB-MIO-E.

5. **Stop `socat` & Restart `wb-mqtt-serial`**:
   - Closes the connection after configuration.  
   - Restores normal operation on Wiren Board.

### Why This Script Matters

- **Default Speed Caveat**: The **WB-MIO-E v1** ships with **9600 baud** for WBIO bus. Changing it to a **different** speed **must** be done in the register.  
- **No Manual Switches**: You cannot switch speeds via hardware DIP settings; it must be done by Modbus write.  
- **Ensures WBIO Compatibility**: By aligning the MIO-E speed with your host and your WBIO modules’ expected parameters, you enable stable polling and communication.

### Example Usage

1. **Clone** the repository:
   ```bash
   git clone https://github.com/kvakirsanov/wb-mio-v1-change-wbio-speed.git
   cd wb-mio-v1-change-wbio-speed
   ```
2. **Edit** the script parameters:
   - `IP_ADDRESS`, `TCP_PORT`, `CURRENT_ADDR`
   - `DEV_PORT`,  
   - `CURRENT_BAUD`, `CURRENT_PARITY`, `CURRENT_STOPBITS`,
   - `SPEED_MAP`.  
3. **Run** the script:
   ```bash
   sudo ./wb-mio-change-speed.sh
   ```
4. **Follow** prompts to:
   - Read current speed,  
   - Change speed (if desired, e.g. from 9600 to 115200),  
   - Write to register 110,  
   - Reboot (register 120) if needed.

### Table of Important Registers

| **Register** | **Hex**  | **Meaning**                   | **R/W** | **Notes**                                                                             |
|:------------:|:--------:|--------------------------------|:-------:|----------------------------------------------------------------------------------------|
| **110**      | 0x006E   | Speed (baud/100)              | R/W     | Default is `96` (→9600). For 115200, set `1152`. Needed to switch from default speed.  |
| **128**      | 0x0080   | Modbus Address                | R/W     | Confirms the target device address.                                                    |
| **120**      | 0x0078   | Reboot Register               | R/W     | Write `1` to reboot if firmware requires this to apply the new speed.                 |
> For more details on registers, refer to the official [WB-MIO Modbus Registers](https://wirenboard.com/wiki/WB-MIO-Modbus-Registers) documentation.

## Conclusion

By default, the WirenBoard **WB-MIO-E v1** runs at **9600** baud. If you require a **different** speed (e.g., 115200) to match your host or your **WBIO** modules' communication needs, you must **write** the new speed code into **Register 110**. Some devices also need a **reboot** via **Register 120**. This interactive script automates the entire process, ensuring you can easily manage the module’s speed, address, and reboot steps without manual confusion or conflicts with `wb-mqtt-serial`.

---

**Happy configuring!**  
If you have suggestions, questions, or issues, open an [Issue](https://github.com/your_org/wb-mio-e-config/issues) or submit a Pull Request in the repository.