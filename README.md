# Wazuh Updater Script

This a quick script for my personal use that updates Wazuh components on a single node deployment running inside a debian-based OS. It includes steps for checking the status of Wazuh components, stopping them, performing updates, and restarting the services.

## How to Use

### Download the Script

1. Download the Script
   ```bash
   curl -o wazuh_server_updater.sh https://raw.githubusercontent.com/Cyber-Gen/Wazuh-Updater/main/wazuh_server_updater.sh
   ```
2. Make it executiable
   ```bash
   chmod +x wazuh_server_updater.sh
   ```
3. Run the script as root
   ```bash
   sudo ./wazuh_server_updater.sh
   ```