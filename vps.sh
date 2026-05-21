#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Fixed QEMU Multi-VM Manager Replica
# Added: Windows 10/11, Stop VM, noVNC-friendly VNC, RDP/Tailscale helpers
# Added: Windows autounattend ISO generator:
#   - attempts to enable RDP
#   - attempts to enable OpenSSH Server
#   - downloads/installs Tailscale during Windows setup
#   - creates a desktop script to run tailscale up --ssh after login
# Fixed: VM folder is created next to this .sh file
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
VM_DIR="${VM_DIR:-$SCRIPT_DIR/vms}"
RUN_DIR="$VM_DIR/run"
mkdir -p "$VM_DIR" "$RUN_DIR"

SUDO=""
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
fi

print_status() {
    local type="$1"; local message="$2"
    case "$type" in
        INFO) echo -e "\033[1;34m[INFO]\033[0m $message" ;;
        WARN) echo -e "\033[1;33m[WARN]\033[0m $message" ;;
        ERROR) echo -e "\033[1;31m[ERROR]\033[0m $message" ;;
        SUCCESS) echo -e "\033[1;32m[SUCCESS]\033[0m $message" ;;
        INPUT) echo -e "\033[1;36m[INPUT]\033[0m $message" ;;
        *) echo "[$type] $message" ;;
    esac
}

display_header() {
    clear || true
    cat << "EOF"
============================================================
              Fixed QEMU Multi-VM Manager
              Windows RDP + SSH + Tailscale Version
============================================================
EOF
    echo
}

declare -A OS_OPTIONS
OS_OPTIONS["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu-vm|ubuntu|ubuntu|cloud"
OS_OPTIONS["Ubuntu 22.04"]="ubuntu|jammy|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img|ubuntu-vm|ubuntu|ubuntu|cloud"
OS_OPTIONS["Debian 12"]="debian|bookworm|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2|debian-vm|debian|debian|cloud"
OS_OPTIONS["Debian 11"]="debian|bullseye|https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-amd64.qcow2|debian-vm|debian|debian|cloud"
OS_OPTIONS["Windows 10 ISO"]="windows|win10|none|windows10-vm|Administrator|password|windows"
OS_OPTIONS["Windows 11 ISO"]="windows|win11|none|windows11-vm|Administrator|password|windows"

validate_input() {
    local type="$1"; local value="$2"
    case "$type" in
        number) [[ "$value" =~ ^[0-9]+$ ]] || { print_status ERROR "Must be a number."; return 1; } ;;
        size) [[ "$value" =~ ^[0-9]+[GgMm]$ ]] || { print_status ERROR "Must be a size with unit, example: 20G or 512M."; return 1; } ;;
        port) [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 23 ] && [ "$value" -le 65535 ] || { print_status ERROR "Must be a valid port from 23 to 65535."; return 1; } ;;
        name) [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]] || { print_status ERROR "Name can only contain letters, numbers, hyphens, and underscores."; return 1; } ;;
        username) [[ "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || { print_status ERROR "Username must start with a letter or underscore."; return 1; } ;;
    esac
    return 0
}

check_dependencies() {
    local deps=("qemu-system-x86_64" "qemu-img" "wget" "curl" "ss" "git" "python3")
    local missing=()
    for dep in "${deps[@]}"; do command -v "$dep" >/dev/null 2>&1 || missing+=("$dep"); done
    if [ "${#missing[@]}" -ne 0 ]; then
        print_status ERROR "Missing dependencies: ${missing[*]}"
        echo "sudo apt update"
        echo "sudo apt install -y qemu-system-x86 qemu-utils wget curl iproute2 genisoimage git python3"
        exit 1
    fi
}

detect_host_os() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        HOST_ID="${ID:-unknown}"; HOST_ID_LIKE="${ID_LIKE:-}"; HOST_NAME="${PRETTY_NAME:-unknown}"
    else
        HOST_ID="unknown"; HOST_ID_LIKE=""; HOST_NAME="unknown"
    fi
}
is_debian_like(){ detect_host_os; [[ "$HOST_ID" == "debian" || "$HOST_ID" == "ubuntu" || "$HOST_ID_LIKE" == *"debian"* || "$HOST_ID_LIKE" == *"ubuntu"* ]]; }
is_fedora_like(){ detect_host_os; [[ "$HOST_ID" == "fedora" || "$HOST_ID" == "rhel" || "$HOST_ID" == "centos" || "$HOST_ID_LIKE" == *"fedora"* || "$HOST_ID_LIKE" == *"rhel"* ]]; }
is_arch_like(){ detect_host_os; [[ "$HOST_ID" == "arch" || "$HOST_ID_LIKE" == *"arch"* ]]; }

detect_accel() {
    if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then echo "kvm"; else echo "tcg"; fi
}
check_kvm_warning() {
    local accel; accel="$(detect_accel)"
    if [ "$accel" = "kvm" ]; then print_status SUCCESS "KVM acceleration is available."
    else print_status WARN "KVM is not available. VM will use TCG software emulation."; fi
}

get_vm_list(){ find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort || true; }

load_vm_config() {
    local vm_name="$1"; local config_file="$VM_DIR/$vm_name.conf"
    [ -f "$config_file" ] || { print_status ERROR "VM config not found: $config_file"; return 1; }
    unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED INSTALL_MODE WINDOWS_ISO RDP_PORT PID_FILE VNC_DISPLAY VNC_PORT AUTOUNATTEND_ISO WIN_AUTOMATION
    source "$config_file"
    PID_FILE="$RUN_DIR/$VM_NAME.pid"
}

save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
INSTALL_MODE="$INSTALL_MODE"
WINDOWS_ISO="${WINDOWS_ISO:-}"
RDP_PORT="${RDP_PORT:-3389}"
VNC_DISPLAY="${VNC_DISPLAY:-1}"
VNC_PORT="${VNC_PORT:-5901}"
AUTOUNATTEND_ISO="${AUTOUNATTEND_ISO:-}"
WIN_AUTOMATION="${WIN_AUTOMATION:-yes}"
EOF
    print_status SUCCESS "Saved config: $config_file"
}

create_cloud_init() {
    local user_data="$VM_DIR/$VM_NAME-user-data"; local meta_data="$VM_DIR/$VM_NAME-meta-data"
    cat > "$user_data" <<EOF
#cloud-config
hostname: $HOSTNAME
manage_etc_hosts: true
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin, sudo
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "$PASSWORD"
ssh_pwauth: true
disable_root: false
package_update: true
packages: [openssh-server, curl, wget, nano, vim, htop, net-tools, ca-certificates]
runcmd:
  - systemctl enable ssh || systemctl enable sshd || true
  - systemctl restart ssh || systemctl restart sshd || true
  - sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
  - sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
  - systemctl restart ssh || systemctl restart sshd || true
final_message: "VM setup complete. Login with SSH."
EOF
    cat > "$meta_data" <<EOF
instance-id: $VM_NAME
local-hostname: $HOSTNAME
EOF
    if command -v cloud-localds >/dev/null 2>&1; then
        cloud-localds "$SEED_FILE" "$user_data" "$meta_data"
    elif command -v genisoimage >/dev/null 2>&1; then
        genisoimage -output "$SEED_FILE" -volid cidata -joliet -rock "$user_data" "$meta_data"
    else
        print_status ERROR "Need cloud-localds or genisoimage for Linux cloud-init."
        exit 1
    fi
    rm -f "$user_data" "$meta_data"
    print_status SUCCESS "Cloud-init seed created: $SEED_FILE"
}

setup_novnc_cloudflared() {
    local vnc_port="${1:-5901}"
    local novnc_port="${2:-6080}"
    local cf_bin="/tmp/cloudflared"
    local novnc_dir="/tmp/noVNC"

    print_status INFO "Setting up noVNC + Cloudflare Tunnel..."
    print_status INFO "IDX/Public Ports: expose these ports if prompted/shown: $novnc_port, $vnc_port"
    print_status INFO "VNC target: localhost:$vnc_port"
    print_status INFO "noVNC web port: localhost:$novnc_port"

    if ! command -v git >/dev/null 2>&1; then
        print_status WARN "git is missing. noVNC auto setup may fail."
    fi

    if [ ! -d "$novnc_dir" ]; then
        print_status INFO "Downloading noVNC..."
        git clone https://github.com/novnc/noVNC.git "$novnc_dir" || true
    fi
    if [ ! -d "$novnc_dir/utils/websockify" ]; then
        print_status INFO "Downloading websockify..."
        git clone https://github.com/novnc/websockify "$novnc_dir/utils/websockify" || true
    fi

    if [ ! -x "$cf_bin" ]; then
        print_status INFO "Downloading cloudflared..."
        local arch
        arch="$(uname -m)"
        case "$arch" in
            x86_64|amd64) curl -L --fail -o "$cf_bin" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 ;;
            aarch64|arm64) curl -L --fail -o "$cf_bin" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 ;;
            *) print_status ERROR "Unsupported arch for cloudflared auto-download: $arch"; return 1 ;;
        esac
        chmod +x "$cf_bin"
    fi

    if ss -tln 2>/dev/null | grep -q ":$novnc_port "; then
        print_status WARN "Port $novnc_port is already listening. Reusing it."
    else
        print_status INFO "Starting noVNC on port $novnc_port -> VNC localhost:$vnc_port"
        (cd "$novnc_dir" && ./utils/novnc_proxy --vnc "localhost:$vnc_port" --listen "$novnc_port" > "/tmp/novnc-$novnc_port.log" 2>&1 &) || true
        sleep 2
    fi

    print_status INFO "Starting Cloudflare Tunnel to noVNC..."
    print_status WARN "Keep this terminal open. The trycloudflare URL will appear below."
    print_status WARN "Open the https://*.trycloudflare.com/vnc.html URL in your browser."
    while true; do
        "$cf_bin" tunnel --edge-ip-version 4 --protocol http2 --url "http://127.0.0.1:$novnc_port"
        print_status WARN "cloudflared stopped or failed. Retrying in 10 seconds..."
        sleep 10
    done
}

create_windows_autounattend_iso() {
    local workdir="$VM_DIR/$VM_NAME-autounattend"
    AUTOUNATTEND_ISO="$VM_DIR/$VM_NAME-autounattend.iso"
    rm -rf "$workdir"; mkdir -p "$workdir/Windows/Setup/Scripts"

    cat > "$workdir/Windows/Setup/Scripts/SetupComplete.cmd" <<'EOF'
@echo off
powershell.exe -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\postinstall.ps1
exit /b 0
EOF

    cat > "$workdir/Windows/Setup/Scripts/postinstall.ps1" <<'EOF'
$ErrorActionPreference = "Continue"
Start-Transcript -Path "C:\Windows\Temp\vm-postinstall.log" -Append

Write-Host "Enabling RDP..."
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 0

Write-Host "Installing/enabling OpenSSH Server..."
try { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 } catch {}
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
New-NetFirewallRule -Name sshd -DisplayName "OpenSSH Server" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue

Write-Host "Downloading and installing Tailscale..."
$tsUrl = "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi"
$tsMsi = "C:\Windows\Temp\tailscale.msi"
try {
  Invoke-WebRequest -Uri $tsUrl -OutFile $tsMsi -UseBasicParsing
  Start-Process msiexec.exe -ArgumentList "/i `"$tsMsi`" /quiet /norestart" -Wait
} catch { Write-Host "Tailscale install failed: $_" }

$helper = @'
$ErrorActionPreference = "Continue"
$tailscale = "C:\Program Files\Tailscale\tailscale.exe"
if (!(Test-Path $tailscale)) {
  Write-Host "Tailscale not found. Install may still be running or failed."
  pause
  exit
}
Write-Host "Running: tailscale up --ssh"
Write-Host "A login URL should appear. Open it in your browser and log in."
& $tailscale up --ssh
Write-Host ""
Write-Host "After login, your Tailscale IP is:"
& $tailscale ip -4
pause
'@
$helperPath = "C:\Users\Public\Desktop\Run Tailscale Login + SSH.ps1"
Set-Content -Path $helperPath -Value $helper -Encoding UTF8
$bat = '@echo off
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\Public\Desktop\Run Tailscale Login + SSH.ps1"
'
Set-Content -Path "C:\Users\Public\Desktop\Run Tailscale Login + SSH.bat" -Value $bat -Encoding ASCII

$tailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
if (Test-Path $tailscaleExe) {
  Start-Process powershell.exe -ArgumentList "-NoExit -ExecutionPolicy Bypass -Command `"& '$tailscaleExe' up --ssh; & '$tailscaleExe' ip -4`""
}
Stop-Transcript
EOF

    cat > "$workdir/autounattend.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><NetworkLocation>Home</NetworkLocation><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Password><Value>$PASSWORD</Value><PlainText>true</PlainText></Password><Description>Local admin account</Description><DisplayName>$USERNAME</DisplayName><Group>Administrators</Group><Name>$USERNAME</Name></LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Password><Value>$PASSWORD</Value><PlainText>true</PlainText></Password><Enabled>true</Enabled><Username>$USERNAME</Username></AutoLogon>
      <FirstLogonCommands><SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>1</Order><Description>Run Tailscale Login Helper</Description><CommandLine>powershell.exe -ExecutionPolicy Bypass -File "C:\Users\Public\Desktop\Run Tailscale Login + SSH.ps1"</CommandLine></SynchronousCommand></FirstLogonCommands>
    </component>
  </settings>
</unattend>
EOF

    if command -v genisoimage >/dev/null 2>&1; then
        genisoimage -quiet -J -r -V "AUTOUNATTEND" -o "$AUTOUNATTEND_ISO" "$workdir"
    elif command -v mkisofs >/dev/null 2>&1; then
        mkisofs -quiet -J -r -V "AUTOUNATTEND" -o "$AUTOUNATTEND_ISO" "$workdir"
    else
        print_status WARN "genisoimage/mkisofs not found. Cannot create Windows automation ISO."
        AUTOUNATTEND_ISO=""
        return 0
    fi
    print_status SUCCESS "Windows automation ISO created: $AUTOUNATTEND_ISO"
}

get_windows_iso() {
    local win_version="$1"; local iso_dir="$VM_DIR/isos"; mkdir -p "$iso_dir"
    echo; print_status INFO "Windows $win_version ISO setup"
    echo "1) Use existing ISO path"; echo "2) Download ISO from direct URL"; echo "3) Show official Microsoft download page"; echo
    while true; do
        read -rp "$(print_status INPUT "Choose ISO option [1-3]: ")" iso_choice
        case "$iso_choice" in
            1) while true; do read -rp "$(print_status INPUT "Windows ISO path: ")" WINDOWS_ISO; [ -f "$WINDOWS_ISO" ] && { print_status SUCCESS "Using ISO: $WINDOWS_ISO"; return 0; }; print_status ERROR "ISO file not found: $WINDOWS_ISO"; done ;;
            2) local iso_url iso_name; read -rp "$(print_status INPUT "Paste direct Windows ISO URL: ")" iso_url; [ -n "$iso_url" ] || { print_status ERROR "URL cannot be empty."; continue; }; iso_name="windows-${win_version}-${VM_NAME}.iso"; WINDOWS_ISO="$iso_dir/$iso_name"; print_status INFO "Downloading ISO to:"; echo "$WINDOWS_ISO"; echo; if command -v curl >/dev/null 2>&1; then curl -L --fail --continue-at - --progress-bar "$iso_url" -o "$WINDOWS_ISO"; else wget -c -O "$WINDOWS_ISO" "$iso_url"; fi; [ -f "$WINDOWS_ISO" ] && { print_status SUCCESS "Downloaded ISO: $WINDOWS_ISO"; return 0; }; print_status ERROR "Download failed."; rm -f "$WINDOWS_ISO" ;;
            3) [ "$win_version" = "11" ] && echo "https://www.microsoft.com/en-us/software-download/windows11" || echo "https://www.microsoft.com/software-download/windows10" ;;
            *) print_status ERROR "Invalid choice." ;;
        esac
    done
}

create_new_vm() {
    display_header; check_dependencies
    print_status INFO "VM directory: $VM_DIR"; echo; print_status INFO "Select an OS:"; echo
    local os_options=(); local i=1
    for os in "${!OS_OPTIONS[@]}"; do echo "  $i) $os"; os_options[$i]="$os"; ((i++)); done
    echo
    while true; do read -rp "$(print_status INPUT "Choice 1-${#OS_OPTIONS[@]}: ")" choice; if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#OS_OPTIONS[@]}" ]; then local selected_os="${os_options[$choice]}"; IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD INSTALL_MODE <<< "${OS_OPTIONS[$selected_os]}"; break; else print_status ERROR "Invalid choice."; fi; done
    while true; do read -rp "$(print_status INPUT "VM name default [$DEFAULT_HOSTNAME]: ")" VM_NAME; VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"; validate_input name "$VM_NAME" && { [ ! -f "$VM_DIR/$VM_NAME.conf" ] && break || print_status ERROR "VM already exists."; }; done
    while true; do read -rp "$(print_status INPUT "Hostname default [$VM_NAME]: ")" HOSTNAME; HOSTNAME="${HOSTNAME:-$VM_NAME}"; validate_input name "$HOSTNAME" && break; done
    while true; do read -rp "$(print_status INPUT "Username default [$DEFAULT_USERNAME]: ")" USERNAME; USERNAME="${USERNAME:-$DEFAULT_USERNAME}"; validate_input username "$USERNAME" && break; done
    while true; do read -srp "$(print_status INPUT "Password default [$DEFAULT_PASSWORD]: ")" PASSWORD; echo; PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"; [ -n "$PASSWORD" ] && break || print_status ERROR "Password cannot be empty."; done

    if [ "$INSTALL_MODE" = "windows" ]; then
        [ "$CODENAME" = "win11" ] && get_windows_iso "11" || get_windows_iso "10"
        while true; do read -rp "$(print_status INPUT "Disk size default [64G]: ")" DISK_SIZE; DISK_SIZE="${DISK_SIZE:-64G}"; validate_input size "$DISK_SIZE" && break; done
        while true; do read -rp "$(print_status INPUT "Memory MB default [4096]: ")" MEMORY; MEMORY="${MEMORY:-4096}"; validate_input number "$MEMORY" && break; done
        while true; do read -rp "$(print_status INPUT "CPUs default [2]: ")" CPUS; CPUS="${CPUS:-2}"; validate_input number "$CPUS" && break; done
        while true; do read -rp "$(print_status INPUT "RDP host port default [3389]: ")" RDP_PORT; RDP_PORT="${RDP_PORT:-3389}"; validate_input port "$RDP_PORT" && { ss -tln 2>/dev/null | grep -q ":$RDP_PORT " && print_status ERROR "Port $RDP_PORT is already in use." || break; }; done
        while true; do read -rp "$(print_status INPUT "VNC display default [:1 / port 5901]: ")" VNC_DISPLAY; VNC_DISPLAY="${VNC_DISPLAY:-1}"; VNC_DISPLAY="${VNC_DISPLAY#:}"; validate_input number "$VNC_DISPLAY" && { VNC_PORT="$((5900 + VNC_DISPLAY))"; ss -tln 2>/dev/null | grep -q ":$VNC_PORT " && print_status ERROR "VNC port $VNC_PORT is already in use." || break; }; done
        read -rp "$(print_status INPUT "Create Windows automation ISO for RDP + SSH + Tailscale? (Y/n): ")" auto_choice; auto_choice="${auto_choice:-y}"
        if [[ "$auto_choice" =~ ^[Yy]$ ]]; then WIN_AUTOMATION="yes"; create_windows_autounattend_iso; else WIN_AUTOMATION="no"; AUTOUNATTEND_ISO=""; fi
        SSH_PORT="2222"; GUI_MODE="vnc"; PORT_FORWARDS=""; IMG_FILE="$VM_DIR/$VM_NAME.img"; SEED_FILE=""; CREATED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        print_status INFO "Creating Windows VM disk..."; qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE"; save_vm_config
        print_status SUCCESS "Windows VM created successfully."; echo; print_status INFO "Start installer with:"; echo "$0 start $VM_NAME"; echo; print_status INFO "VNC will be available on: localhost:$VNC_PORT"; return
    fi

    WINDOWS_ISO=""; RDP_PORT="3389"; VNC_DISPLAY="1"; VNC_PORT="5901"; AUTOUNATTEND_ISO=""; WIN_AUTOMATION="no"
    while true; do read -rp "$(print_status INPUT "Disk size default [20G]: ")" DISK_SIZE; DISK_SIZE="${DISK_SIZE:-20G}"; validate_input size "$DISK_SIZE" && break; done
    while true; do read -rp "$(print_status INPUT "Memory MB default [1024]: ")" MEMORY; MEMORY="${MEMORY:-1024}"; validate_input number "$MEMORY" && break; done
    while true; do read -rp "$(print_status INPUT "CPUs default [1]: ")" CPUS; CPUS="${CPUS:-1}"; validate_input number "$CPUS" && break; done
    while true; do read -rp "$(print_status INPUT "SSH host port default [2222]: ")" SSH_PORT; SSH_PORT="${SSH_PORT:-2222}"; validate_input port "$SSH_PORT" && { ss -tln 2>/dev/null | grep -q ":$SSH_PORT " && print_status ERROR "Port $SSH_PORT is already in use." || break; }; done
    GUI_MODE="false"; read -rp "$(print_status INPUT "Extra port forwards, example 8080:80,25565:25565 or empty: ")" PORT_FORWARDS; PORT_FORWARDS="${PORT_FORWARDS:-}"
    IMG_FILE="$VM_DIR/$VM_NAME.img"; BASE_IMG="$VM_DIR/$VM_NAME-base.img"; SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"; CREATED="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    print_status INFO "Downloading cloud image..."; wget -O "$BASE_IMG" "$IMG_URL"; print_status INFO "Creating VM disk..."; qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$IMG_FILE" "$DISK_SIZE"; print_status INFO "Creating cloud-init seed..."; create_cloud_init; save_vm_config; print_status SUCCESS "VM created successfully."; echo "$0 start $VM_NAME"
}

build_netdev_args() {
    local netdev="user,id=net0,hostfwd=tcp::$SSH_PORT-:22"
    [ "${INSTALL_MODE:-cloud}" = "windows" ] && netdev="user,id=net0,hostfwd=tcp::${RDP_PORT:-3389}-:3389,hostfwd=tcp::${SSH_PORT:-2222}-:22"
    if [ -n "${PORT_FORWARDS:-}" ]; then IFS=',' read -ra forwards <<< "$PORT_FORWARDS"; for forward in "${forwards[@]}"; do local host_port="${forward%%:*}"; local guest_port="${forward##*:}"; [[ "$host_port" =~ ^[0-9]+$ && "$guest_port" =~ ^[0-9]+$ ]] && netdev+=",hostfwd=tcp::$host_port-:$guest_port" || print_status WARN "Skipping invalid port forward: $forward"; done; fi
    echo "$netdev"
}

start_vm() {
    local vm_name="$1"

    check_dependencies
    load_vm_config "$vm_name"

    : "${MEMORY:=1024}"
    : "${CPUS:=1}"
    : "${SSH_PORT:=2222}"
    : "${GUI_MODE:=false}"
    : "${PORT_FORWARDS:=}"
    : "${INSTALL_MODE:=cloud}"
    : "${RDP_PORT:=3389}"
    : "${VNC_DISPLAY:=1}"
    : "${VNC_PORT:=$((5900 + VNC_DISPLAY))}"
    : "${AUTOUNATTEND_ISO:=}"

    PID_FILE="$RUN_DIR/$VM_NAME.pid"
    local TMUX_SESSION="vps-$VM_NAME"
    local QEMU_CMD_FILE="$RUN_DIR/$VM_NAME-qemu-start.sh"

    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            print_status ERROR "VM already running with PID $old_pid."
            print_status INFO "Attach console with: $0 console $VM_NAME"
            exit 1
        else
            rm -f "$PID_FILE"
        fi
    fi

    [ -f "$IMG_FILE" ] || { print_status ERROR "Missing disk image: $IMG_FILE"; exit 1; }

    if [ "$INSTALL_MODE" != "windows" ]; then
        [ -f "$SEED_FILE" ] || { print_status WARN "Missing seed ISO. Recreating..."; create_cloud_init; }
        ss -tln 2>/dev/null | grep -q ":$SSH_PORT " && { print_status ERROR "SSH port $SSH_PORT is already in use."; exit 1; }
    else
        [ -f "${WINDOWS_ISO:-}" ] || { print_status ERROR "Windows ISO missing: ${WINDOWS_ISO:-}"; exit 1; }
        ss -tln 2>/dev/null | grep -q ":$RDP_PORT " && { print_status ERROR "RDP port $RDP_PORT is already in use."; exit 1; }
        ss -tln 2>/dev/null | grep -q ":$VNC_PORT " && { print_status ERROR "VNC port $VNC_PORT is already in use."; exit 1; }
    fi

    local accel CPU_ARG netdev
    accel="$(detect_accel)"
    if [ "$accel" = "kvm" ]; then
        print_status SUCCESS "Using KVM acceleration."
        CPU_ARG="host"
    else
        print_status WARN "Using TCG software emulation. Boot may be slow."
        CPU_ARG="max"
    fi
    netdev="$(build_netdev_args)"

    print_status INFO "Starting VM: $VM_NAME"
    print_status INFO "VM directory: $VM_DIR"
    print_status INFO "RAM: ${MEMORY}MB"
    print_status INFO "CPUs: $CPUS"

    if [ "$INSTALL_MODE" = "windows" ]; then
        print_status INFO "Windows ISO: $WINDOWS_ISO"
        print_status INFO "RDP forward: host $RDP_PORT -> guest 3389"
        print_status INFO "SSH forward: host ${SSH_PORT:-2222} -> guest 22"
        print_status INFO "Headless display: VNC :$VNC_DISPLAY / localhost:$VNC_PORT"
        [ -n "$AUTOUNATTEND_ISO" ] && [ -f "$AUTOUNATTEND_ISO" ] && print_status INFO "Automation ISO: $AUTOUNATTEND_ISO"
        echo

        local extra_drive_line=""
        if [ -n "$AUTOUNATTEND_ISO" ] && [ -f "$AUTOUNATTEND_ISO" ]; then
            extra_drive_line="-drive file=$AUTOUNATTEND_ISO,format=raw,media=cdrom,if=ide,index=3"
        fi

        cat > "$QEMU_CMD_FILE" <<EOF
#!/usr/bin/env bash
exec qemu-system-x86_64 \\
  -name "$VM_NAME" \\
  -machine "q35,accel=$accel" \\
  -cpu "$CPU_ARG" \\
  -smp "$CPUS",sockets=1,cores="$CPUS",threads=1 \\
  -m "$MEMORY" \\
  -device ich9-ahci,id=sata \\
  -drive "file=$IMG_FILE,format=qcow2,if=none,id=drive0,cache=writeback,discard=unmap" \\
  -device ide-hd,drive=drive0,bus=sata.0 \\
  -drive "file=$WINDOWS_ISO,media=cdrom,if=none,id=cdrom0,readonly=on" \\
  -device ide-cd,drive=cdrom0,bus=sata.1 \\
  $extra_drive_line \\
  -boot menu=on,order=d \\
  -netdev "$netdev" \\
  -device e1000,netdev=net0 \\
  -device qemu-xhci,id=xhci \\
  -device usb-tablet,bus=xhci.0 \\
  -device virtio-rng-pci \\
  -rtc base=localtime,clock=host \\
  -vga std \\
  -display "vnc=127.0.0.1:$VNC_DISPLAY" \\
  -no-shutdown 2>&1 | tee -a "$RUN_DIR/$VM_NAME.qemu.log"
EOF
    else
        print_status INFO "SSH: ssh $USERNAME@localhost -p $SSH_PORT"
        print_status INFO "Console mode is available with: $0 console $VM_NAME"
        cat > "$QEMU_CMD_FILE" <<EOF
#!/usr/bin/env bash
exec qemu-system-x86_64 \\
  -name "$VM_NAME" \\
  -machine "accel=$accel" \\
  -cpu "$CPU_ARG" \\
  -smp "$CPUS" \\
  -m "$MEMORY" \\
  -drive "file=$IMG_FILE,format=qcow2,if=virtio,cache=writeback,discard=unmap" \\
  -drive "file=$SEED_FILE,format=raw,if=virtio,readonly=on" \\
  -netdev "$netdev" \\
  -device virtio-net-pci,netdev=net0 \\
  -device virtio-rng-pci \\
  -device virtio-balloon-pci \\
  -nographic \\
  -serial mon:stdio \\
  -no-shutdown 2>&1 | tee -a "$RUN_DIR/$VM_NAME.qemu.log"
EOF
    fi

    chmod +x "$QEMU_CMD_FILE"

    if command -v tmux >/dev/null 2>&1; then
        tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
        tmux new-session -d -s "$TMUX_SESSION" "$QEMU_CMD_FILE"
        sleep 1
        local qemu_pid
        qemu_pid="$(pgrep -f "qemu-system-x86_64.*-name $VM_NAME" | head -n 1 || true)"
        if [ -z "$qemu_pid" ]; then
            print_status ERROR "VM failed to start. Check log: $RUN_DIR/$VM_NAME.qemu.log"
            exit 1
        fi
        echo "$qemu_pid" > "$PID_FILE"
        print_status SUCCESS "VM started detached in tmux with PID $qemu_pid"
        print_status INFO "Console attach command: $0 console $VM_NAME"
        print_status INFO "Detach without stopping VM: Ctrl+B then D"
    else
        nohup "$QEMU_CMD_FILE" > "$RUN_DIR/$VM_NAME.qemu.log" 2>&1 &
        local qemu_pid="$!"
        echo "$qemu_pid" > "$PID_FILE"
        disown "$qemu_pid" 2>/dev/null || true
        print_status SUCCESS "VM started detached with PID $qemu_pid"
        print_status WARN "tmux not found, so console re-attach is unavailable."
    fi

    print_status INFO "PID file: $PID_FILE"
    print_status INFO "QEMU log: $RUN_DIR/$VM_NAME.qemu.log"

    if [ "$INSTALL_MODE" = "windows" ]; then
        echo
        print_status INFO "Connect VNC/noVNC to localhost:$VNC_PORT"
        print_status INFO "After Windows setup, run the desktop helper if it doesn't auto-open: Run Tailscale Login + SSH.bat"
        print_status INFO "Auto-starting noVNC + cloudflared now..."
        setup_novnc_cloudflared "$VNC_PORT" 6080
    fi
}

stop_vm() { local vm_name="$1"; load_vm_config "$vm_name"; PID_FILE="$RUN_DIR/$VM_NAME.pid"; if [ -f "$PID_FILE" ]; then local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"; if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then print_status INFO "Stopping VM $VM_NAME with PID $pid..."; kill "$pid" || true; for _ in {1..10}; do kill -0 "$pid" 2>/dev/null && sleep 1 || break; done; kill -0 "$pid" 2>/dev/null && { print_status WARN "Force killing..."; kill -9 "$pid" || true; }; rm -f "$PID_FILE"; print_status SUCCESS "Stopped VM: $VM_NAME"; return; else rm -f "$PID_FILE"; fi; fi; print_status WARN "No PID file found or VM is not running. Trying fallback..."; pkill -f "qemu-system-x86_64.*-name $VM_NAME" || true; pkill -f "qemu-system-x86_64.*$VM_NAME" || true; print_status SUCCESS "Stop command completed for: $VM_NAME"; }
repair_vm() { local vm_name="$1"; check_dependencies; load_vm_config "$vm_name"; print_status INFO "Repairing VM: $VM_NAME"; stop_vm "$VM_NAME" || true; [ -f "$IMG_FILE" ] && { qemu-img check "$IMG_FILE" || true; qemu-img check -r all "$IMG_FILE" || true; } || print_status ERROR "Missing disk image: $IMG_FILE"; if [ "${INSTALL_MODE:-cloud}" != "windows" ]; then rm -f "$SEED_FILE"; create_cloud_init; fi; check_kvm_warning; free -h || true; df -h "$VM_DIR" || true; print_status SUCCESS "Repair complete."; echo "$0 start $VM_NAME"; }
delete_vm() { local vm_name="$1"; load_vm_config "$vm_name"; echo; print_status WARN "This will delete VM: $VM_NAME"; read -rp "Type DELETE to confirm: " confirm; [ "$confirm" = "DELETE" ] || { print_status INFO "Cancelled."; exit 0; }; stop_vm "$VM_NAME" || true; rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$VM_NAME.conf" "$VM_DIR/$VM_NAME-base.img" "$RUN_DIR/$VM_NAME.pid" "${AUTOUNATTEND_ISO:-}"; rm -rf "$VM_DIR/$VM_NAME-autounattend"; print_status SUCCESS "Deleted VM: $VM_NAME"; }
console_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name"

    local session="vps-${VM_NAME}"

    if command -v tmux >/dev/null 2>&1; then
        if tmux has-session -t "$session" 2>/dev/null; then
            print_status INFO "Attaching to VM console session: $session"
            print_status INFO "Detach without stopping VM: Ctrl+B then D"
            tmux attach -t "$session"
        else
            print_status ERROR "No console session found for $VM_NAME. Start it with: $0 start $VM_NAME"
            exit 1
        fi
    else
        print_status ERROR "tmux is not installed, so console re-attach is unavailable."
        print_status INFO "Install tmux if possible, or use VNC/noVNC for Windows."
        exit 1
    fi
}

ssh_vm() {
    local vm_name="$1"
    load_vm_config "$vm_name"

    : "${SSH_PORT:=2222}"
    : "${USERNAME:=}"
    : "${INSTALL_MODE:=cloud}"

    if [ -z "${USERNAME:-}" ]; then
        print_status ERROR "Username missing in VM config."
        exit 1
    fi

    print_status INFO "SSH command:"
    echo "ssh $USERNAME@localhost -p $SSH_PORT"
    echo

    if [ "${INSTALL_MODE:-cloud}" = "windows" ]; then
        print_status WARN "For Windows, SSH only works after OpenSSH Server is installed/enabled inside Windows."
        print_status INFO "The Windows automation ISO attempts to enable OpenSSH automatically."
    fi

    print_status INFO "Connecting now..."
    exec ssh "$USERNAME@localhost" -p "$SSH_PORT"
}

show_info() { local vm_name="$1"; load_vm_config "$vm_name"; : "${VNC_DISPLAY:=1}"; : "${VNC_PORT:=$((5900 + VNC_DISPLAY))}"; echo; print_status INFO "VM Info"; echo "Name:       $VM_NAME"; echo "OS:         $OS_TYPE $CODENAME"; echo "Hostname:   $HOSTNAME"; echo "Username:   $USERNAME"; echo "Disk:       $DISK_SIZE"; echo "Memory:     $MEMORY MB"; echo "CPUs:       $CPUS"; echo "Mode:       ${INSTALL_MODE:-cloud}"; echo "SSH Port:   $SSH_PORT"; echo "RDP Port:   ${RDP_PORT:-3389}"; echo "VNC Port:   ${VNC_PORT:-5901}"; echo "Image:      $IMG_FILE"; echo "ISO:        ${WINDOWS_ISO:-}"; echo "Automation: ${AUTOUNATTEND_ISO:-}"; echo "VM Dir:     $VM_DIR"; echo "Created:    $CREATED"; PID_FILE="$RUN_DIR/$VM_NAME.pid"; if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then echo "Status:     Running"; else echo "Status:     Stopped"; fi; echo; if [ "${INSTALL_MODE:-cloud}" = "windows" ]; then echo "VNC/noVNC target: localhost:${VNC_PORT:-5901}"; echo "RDP after Windows setup: localhost:${RDP_PORT:-3389}"; echo "SSH after Windows setup: ssh $USERNAME@localhost -p ${SSH_PORT:-2222}"; else echo "SSH command: ssh $USERNAME@localhost -p $SSH_PORT"; fi; }
list_vms() { display_header; local vms; vms="$(get_vm_list)"; [ -z "$vms" ] && { print_status INFO "No VMs found."; print_status INFO "VM directory: $VM_DIR"; return; }; print_status INFO "Available VMs:"; print_status INFO "VM directory: $VM_DIR"; echo; while read -r vm; do [ -z "$vm" ] && continue; local status="stopped"; local pid_file="$RUN_DIR/$vm.pid"; if [ -f "$pid_file" ]; then local pid; pid="$(cat "$pid_file" 2>/dev/null || true)"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && status="running"; fi; echo "  - $vm [$status]"; done <<< "$vms"; echo; }
install_rdp() { display_header; detect_host_os; print_status INFO "RDP Installer"; print_status INFO "Detected OS: $HOST_NAME"; echo; read -rp "$(print_status INPUT "Continue with RDP installation? (y/n): ")" confirm; confirm="${confirm:-n}"; [[ "$confirm" =~ ^[Yy]$ ]] || { print_status INFO "Cancelled."; return; }; if is_debian_like; then $SUDO apt update; $SUDO apt install -y xrdp xfce4 xfce4-goodies dbus-x11; echo "startxfce4" | $SUDO tee /etc/skel/.xsession >/dev/null; [ -n "${USER:-}" ] && [ "$USER" != "root" ] && echo "startxfce4" > "$HOME/.xsession" || true; $SUDO systemctl enable xrdp; $SUDO systemctl restart xrdp; command -v ufw >/dev/null 2>&1 && $SUDO ufw allow 3389/tcp || true; elif is_fedora_like; then command -v dnf >/dev/null 2>&1 && $SUDO dnf install -y xrdp @xfce-desktop-environment || $SUDO yum install -y xrdp xfce4-session; echo "startxfce4" | $SUDO tee /etc/skel/.xsession >/dev/null; $SUDO systemctl enable xrdp; $SUDO systemctl restart xrdp; elif is_arch_like; then $SUDO pacman -Sy --noconfirm xrdp xfce4 xfce4-goodies; echo "startxfce4" | $SUDO tee /etc/skel/.xsession >/dev/null; $SUDO systemctl enable xrdp; $SUDO systemctl restart xrdp; else print_status ERROR "Unsupported OS."; return 1; fi; print_status SUCCESS "RDP installation complete."; }
install_tailscale() { display_header; detect_host_os; print_status INFO "Tailscale Installer"; print_status INFO "Detected OS: $HOST_NAME"; echo; read -rp "$(print_status INPUT "Continue with Tailscale installation? (y/n): ")" confirm; confirm="${confirm:-n}"; [[ "$confirm" =~ ^[Yy]$ ]] || { print_status INFO "Cancelled."; return; }; command -v curl >/dev/null 2>&1 || { print_status ERROR "curl missing."; return 1; }; curl -fsSL https://tailscale.com/install.sh | sh; command -v systemctl >/dev/null 2>&1 && $SUDO systemctl enable --now tailscaled || true; print_status SUCCESS "Tailscale installed."; read -rp "$(print_status INPUT "Run 'tailscale up' now? (y/n): ")" run_up; run_up="${run_up:-y}"; [[ "$run_up" =~ ^[Yy]$ ]] && $SUDO tailscale up || true; }
show_vm_menu() { display_header; print_status INFO "VM directory: $VM_DIR"; echo; echo "1) Create VM"; echo "2) Start VM"; echo "3) Stop VM"; echo "4) Repair VM"; echo "5) List VMs"; echo "6) VM Info"; echo "7) Delete VM"; echo "8) Check KVM"; echo "9) SSH into VM"; echo "10) Attach VM Console"; echo "0) Exit"; echo; read -rp "$(print_status INPUT "Choose: ")" choice; case "$choice" in 1) create_new_vm ;; 2) list_vms; read -rp "$(print_status INPUT "VM name to start: ")" vm_name; start_vm "$vm_name" ;; 3) list_vms; read -rp "$(print_status INPUT "VM name to stop: ")" vm_name; stop_vm "$vm_name" ;; 4) list_vms; read -rp "$(print_status INPUT "VM name to repair: ")" vm_name; repair_vm "$vm_name" ;; 5) list_vms ;; 6) list_vms; read -rp "$(print_status INPUT "VM name: ")" vm_name; show_info "$vm_name" ;; 7) list_vms; read -rp "$(print_status INPUT "VM name to delete: ")" vm_name; delete_vm "$vm_name" ;; 8) check_kvm_warning ;; 9) list_vms; read -rp "$(print_status INPUT "VM name to SSH into: ")" vm_name; ssh_vm "$vm_name" ;; 10) list_vms; read -rp "$(print_status INPUT "VM name console to attach: ")" vm_name; console_vm "$vm_name" ;; 0) exit 0 ;; *) print_status ERROR "Invalid option." ;; esac; }
show_main_menu() { display_header; print_status INFO "Script directory: $SCRIPT_DIR"; print_status INFO "VM directory: $VM_DIR"; echo; echo "1) VM Installer"; echo "2) RDP Installer"; echo "3) Tailscale Installer"; echo "0) Exit"; echo; read -rp "$(print_status INPUT "Choose: ")" choice; case "$choice" in 1) show_vm_menu ;; 2) install_rdp ;; 3) install_tailscale ;; 0) exit 0 ;; *) print_status ERROR "Invalid option." ;; esac; }
usage() { echo "Usage:"; echo "  $0 menu|vm|rdp-install|tailscale-install|novnc-cloudflared|create|list|check-kvm"; echo "  $0 start <vm-name>"; echo "  $0 stop <vm-name>"; echo "  $0 ssh <vm-name>"; echo "  $0 console <vm-name>"; echo "  $0 repair <vm-name>"; echo "  $0 info <vm-name>"; echo "  $0 delete <vm-name>"; echo; echo "VM directory: $VM_DIR"; }
main() { local cmd="${1:-menu}"; case "$cmd" in menu) show_main_menu ;; vm) show_vm_menu ;; rdp-install) install_rdp ;; tailscale-install) install_tailscale ;; novnc-cloudflared) setup_novnc_cloudflared "${2:-5901}" "${3:-6080}" ;; create) create_new_vm ;; start) [ $# -lt 2 ] && { usage; exit 1; }; start_vm "$2" ;; console) [ $# -lt 2 ] && { usage; exit 1; }; console_vm "$2" ;; ssh) [ $# -lt 2 ] && { usage; exit 1; }; ssh_vm "$2" ;; stop) [ $# -lt 2 ] && { usage; exit 1; }; stop_vm "$2" ;; repair) [ $# -lt 2 ] && { usage; exit 1; }; repair_vm "$2" ;; list) list_vms ;; info) [ $# -lt 2 ] && { usage; exit 1; }; show_info "$2" ;; delete) [ $# -lt 2 ] && { usage; exit 1; }; delete_vm "$2" ;; check-kvm) check_kvm_warning ;; *) usage; exit 1 ;; esac; }
main "$@"
