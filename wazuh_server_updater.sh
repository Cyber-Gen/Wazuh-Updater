#!/bin/bash

backup_file="/var/ossec/etc/ossec.conf.$(date +'%Y%m%d%H%M%S')"
services=("filebeat" "wazuh-dashboard" "wazuh-indexer" "wazuh-manager")

# Associative arrays to define order for stopping, updating, and starting
declare -A stop_order
stop_order=([filebeat]=1 [wazuh-dashboard]=2 [wazuh-indexer]=3)

declare -A update_order
update_order=([wazuh-indexer]=1 [wazuh-manager]=2 [wazuh-dashboard]=3)

declare -A start_order
start_order=([wazuh-indexer]=1 [filebeat]=2 [wazuh-dashboard]=3)

handle_error() {
    local exit_code=$?
    echo "Error: Something went wrong. Exiting with code $exit_code."
    exit $exit_code
}

handle_sigint() {
    echo -e "\nWarning: You pressed Ctrl+C. Exiting now may break the installation and upgrade process."
    if [[ $(prompt_yes_no "Do you really want to exit?") == "y" ]]; then
        exit 1
    fi
}

trap handle_sigint SIGINT

check_status() {
    service_name=$1
    echo "Checking status of $service_name..."
    sudo systemctl is-active --quiet $service_name && echo "$service_name is running." || echo "$service_name is not running."
    sudo systemctl is-enabled --quiet $service_name && echo "$service_name is enabled." || echo "$service_name is not enabled."
}

enable_service() {
    service_name=$1
    echo "Enabling $service_name..."
    sudo systemctl enable $service_name || handle_error
    sleep 3
}

start_service() {
    service_name=$1
    echo "Starting $service_name..."
    sudo systemctl start $service_name || handle_error
    sleep 10
}

upgrade_wazuh() {
    echo "Updating package list..."
    sudo apt update -y || handle_error
    sleep 3
    echo "Updating Wazuh components..."
    for service_name in "${services[@]}"; do
        if [[ ${update_order[$service_name]+_} ]]; then
            sudo apt install $service_name -y || handle_error
        fi
    done
}

validate_url() {
    url=$1
    if [[ $url =~ ^https?://.+ ]]; then
        return 0
    else
        return 1
    fi
}

prompt_for_url() {
    local prompt_message=$1
    local input_url
    while true; do
        read -p "$prompt_message" input_url
        if validate_url $input_url; then
            echo $input_url
            return
        else
            echo "Invalid URL. Please enter a valid URL."
        fi
    done
}

prompt_yes_no() {
    local prompt_message=$1
    local input
    while true; do
        read -p "$prompt_message (y/n): " input
        case $input in
            [Yy]* ) echo "y"; return;;
            [Nn]* ) echo "n"; return;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

prompt_upgrade_type() {
    local prompt_message=$1
    local input
    while true; do
        read -p "$prompt_message (soft/full): " input
        case $input in
            soft ) echo "soft"; return;;
            full ) echo "full"; return;;
            * ) echo "Please answer soft or full.";;
        esac
    done
}

echo "Checking status of Wazuh server components..."
for service_name in "${services[@]}"; do
    check_status $service_name
done
sleep 10

# Stop Wazuh components in order
echo "Stopping Wazuh server components..."
for service_name in $(for s in "${services[@]}"; do echo "${stop_order[$s]} $s"; done | sort -n | cut -d' ' -f2); do
    echo "stopping $service_name..."
    sudo systemctl stop $service_name || handle_error
    sleep 5
done

echo "Backing up ossec.conf to $backup_file..."
sudo cp /var/ossec/etc/ossec.conf "$backup_file" || handle_error

# Updating & Upgrading
upgrade_wazuh

upgrade_type=$(prompt_upgrade_type "Do you want to perform a soft upgrade or a full upgrade?")
if [[ $upgrade_type == "full" ]]; then
    echo "Warning: Full upgrade may potentially break stuff and packages."
    echo "It may also remove some packages."
    proceed_full_upgrade=$(prompt_yes_no "Do you want to proceed with full upgrade?")
    if [[ $proceed_full_upgrade == "y" ]]; then
        echo "Performing full upgrade..."
        sudo apt full-upgrade -y || handle_error
        echo "Removing unnecessary packages..."
        sudo apt autoremove -y || handle_error
    else
        echo "Full upgrade aborted."
    fi
else
    echo "Performing soft upgrade..."
    sudo apt upgrade -y || handle_error
fi
sleep 5

# Post Upgrade re-checks
upgrade_wazuh
sleep 5

# Install Filebeat
filebeat_url="https://packages.wazuh.com/4.x/filebeat/wazuh-filebeat-0.3.tar.gz"
echo "The Filebeat installation URL is: $filebeat_url"
filebeat_url_input=$(prompt_yes_no "Does the URL look correct?")
if [[ $filebeat_url_input == "y" ]]; then
    echo "Downloading and extracting Filebeat from $filebeat_url..."
    curl -s $filebeat_url | sudo tar -xvz -C /usr/share/filebeat/module || handle_error
    sleep 5
else
    read -p "Would you like to provide the correct URL? (y/n): " correct_filebeat_url_input
    if [[ $correct_filebeat_url_input == "y" ]]; then
        correct_filebeat_url=$(prompt_for_url "Please provide the correct URL: ")
        echo "Downloading and extracting Filebeat from $correct_filebeat_url..."
        curl -s $correct_filebeat_url | sudo tar -xvz -C /usr/share/filebeat/module || handle_error
        sleep 5
    else
        echo "Skipping Filebeat installation."
    fi
fi

# Fetch Wazuh version to construct alerts template URL
wazuh_version=$(dpkg-query --showformat='${Version}' --show wazuh-manager | cut -d'-' -f1) || handle_error
template_url="https://raw.githubusercontent.com/wazuh/wazuh/v${wazuh_version}/extensions/elasticsearch/7.x/wazuh-template.json"

echo "The constructed alerts template URL is: $template_url"
template_url_input=$(prompt_yes_no "Does the URL look correct?")
if [[ $template_url_input == "y" ]]; then
    echo "Downloading alerts template from $template_url..."
    sudo curl -so /etc/filebeat/wazuh-template.json $template_url || handle_error
    sudo chmod go+r /etc/filebeat/wazuh-template.json || handle_error
    sleep 5
else
    read -p "Would you like to provide the correct URL? (y/n): " correct_template_url_input
    if [[ $correct_template_url_input == "y" ]]; then
        correct_template_url=$(prompt_for_url "Please provide the correct URL: ")
        echo "Downloading alerts template from $correct_template_url..."
        sudo curl -so /etc/filebeat/wazuh-template.json $correct_template_url || handle_error
        sudo chmod go+r /etc/filebeat/wazuh-template.json || handle_error
        sleep 5
    else
        echo "Skipping alerts template download."
    fi
fi

echo "Reloading systemd config..."
sudo systemctl daemon-reload || handle_error
sleep 3

# Enable and start Wazuh components in order
echo "Enabling Wazuh server components..."
for service_name in $(for s in "${services[@]}"; do echo "${start_order[$s]} $s"; done | sort -n | cut -d' ' -f2); do
    enable_service $service_name
done

echo "Starting Wazuh server components..."
for service_name in $(for s in "${services[@]}"; do echo "${start_order[$s]} $s"; done | sort -n | cut -d' ' -f2); do
    start_service $service_name
done

echo "Checking status of Wazuh server components..."
for service_name in "${services[@]}"; do
    check_status $service_name
done

echo "Update and restart process completed."
