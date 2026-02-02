#!/bin/bash

# ==============================================================================
# Global Variables and Configuration
# ==============================================================================
DEBUG=0
DEBUG_LOG="fake_ap_debug.log"
PROGNAME=${0##*/}
LOCKFILE="/var/run/${PROGNAME%%.*}.pid"
BACKTITLE="Fake Access Point SSID Generator"
SSID_DIR="./ssid_lists"
DUMMY_FILE="$SSID_DIR/dummy-list.txt"
CLEANED_UP=false
STEP=1
LAST_ITEM_IFACE="ALL"
LAST_ITEM_SSID="ALL"
COMBINED_SSID_FILE=""

# Arrays and Associative Arrays
declare -A IFACE_MANAGED_STATE
declare -A SELECTED_SSIDS
declare -A SELECTED_INTERFACES
declare -A TOUCHED_INTERFACES
declare -a MDK_PIDS
declare -A IFACE_IP
declare -A IFACE_INTERNET

# Temporary files
DIALOGRC=$(mktemp /tmp/fake_ap_dialogrc.XXXXXX)
CHOICE_FILE=$(mktemp /tmp/fake_ap_choice.XXXXXX)

# ==============================================================================
# Function Definitions
# ==============================================================================

log_debug() {
    if [[ "$DEBUG" == "1" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEBUG_LOG"
    fi
}

check_dep() {
    local cmd=$1
    local pkg=$2
    if ! command -v "$cmd" &> /dev/null; then
        printf "%-50s" "[+] Installing $pkg"
        if apt-get update -qq && apt-get install -y -qq "$pkg" &> /dev/null; then
            echo "[OK]"
        else
            echo "[FAILED]"
            exit -1
        fi
    fi
}

cleanup() {
    if [[ "$CLEANED_UP" == "true" ]]; then return; fi
    CLEANED_UP=true

    # Lockfile cleanup
    if [ -e "${LOCKFILE:-/missing}" ]; then
        LOCKPID=$(cat "${LOCKFILE:-/missing}" 2>/dev/null)
        if [ "$$" -eq "${LOCKPID:-empty}" ]; then
            rm -f "${LOCKFILE:-/missing}"
        fi
    fi

    clear
    echo -e "\n[+] Cleaning up..."
    log_debug "Cleanup initiated"
    for pid in "${MDK_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then 
            log_debug "Killing mdk4 process $pid"
            kill "$pid" 2>/dev/null
        fi
    done
    # Helper for stop with timeout
    t_stop() {
        if command -v timeout &>/dev/null; then timeout 8 airmon-ng stop "$1" >/dev/null 2>&1
        else airmon-ng stop "$1" >/dev/null 2>&1; fi
    }

    for iface in "${!TOUCHED_INTERFACES[@]}"; do
        echo "[+] Restoring $iface..."
        log_debug "Restoring interface $iface"
        t_stop "${iface}mon"
        t_stop "${iface}min"
        t_stop "$iface"
        if [[ "${IFACE_MANAGED_STATE[$iface]}" == "managed" ]]; then
            nmcli device set "$iface" managed yes >/dev/null 2>&1
        fi
    done
    rm -f "$DIALOGRC" "$CHOICE_FILE" "$COMBINED_SSID_FILE"
    echo "[+] Cleanup complete. Exiting."
    exit 0
}

set_color() {
    local key=$1
    local value=$2
    if grep -q "^$key =" "$DIALOGRC" 2>/dev/null; then sed -i "s/^$key =.*/$key = $value/" "$DIALOGRC"; fi
}

get_interfaces() { iw dev 2>/dev/null | grep Interface | awk '{print $2}' | grep -v -E "eth0|wwan|lo"; }

get_interface_info() {
    local iface=$1
    local ip_addr=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    local internet="NO"
    if [[ -n "$ip_addr" ]]; then if ping -c 1 -W 1 -I "$iface" 8.8.8.8 >/dev/null 2>&1; then internet="YES"; fi; fi
    echo "${ip_addr:-None}|$internet"
}

# ==============================================================================
# Initial Setup and Checks
# ==============================================================================

trap cleanup SIGINT SIGTERM EXIT

# Root check
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)."
   exit 1
fi

# Check for already running script
if [ -e "${LOCKFILE}" ]; then
    # There is a lockfile
    OLD_PROCESS_PID="$(cat "${LOCKFILE}")"
    PROCESS_FOUND="$(ps -p "${OLD_PROCESS_PID}" -o pid 2>/dev/null | grep -cv PID)"
    # Check if old process is running
    if [ "${PROCESS_FOUND}" -ne 0 ]; then
        # The PID found in the lockfile is running
        echo "### ERROR - Lockfile ${LOCKFILE} exist."
        echo "            This script is already running with PID: ${OLD_PROCESS_PID}"
        echo ""
        exit 3
    else
        # The PID found in the lockfile is NOT running - remove the lock file
        rm -f "${LOCKFILE}"
        echo -e "### WARNING ###\tOld lockfile found but process was not running - writing new lockfile"
    fi
fi
echo $$ > "${LOCKFILE}"

# Dependency check
log_debug "Starting script. System check."
check_dep "airmon-ng" "aircrack-ng"
check_dep "mdk4" "mdk4"
check_dep "dialog" "dialog"
check_dep "nmcli" "network-manager"
check_dep "iw" "iw"

# Initialize Dialog configuration
dialog --create-rc "$DIALOGRC" >/dev/null 2>&1
set_color "use_shadow" "ON"
set_color "use_colors" "ON"
set_color "screen_color" "(WHITE,BLACK,OFF)"
set_color "dialog_color" "(WHITE,BLUE,ON)"
set_color "title_color" "(YELLOW,BLUE,ON)"
set_color "border_color" "(WHITE,BLUE,ON)"
set_color "item_selected_color" "(WHITE,CYAN,ON)"
set_color "tag_selected_color" "(WHITE,CYAN,ON)"
set_color "tag_key_color" "(WHITE,BLUE,ON)"
set_color "tag_key_selected_color" "(WHITE,CYAN,ON)"
set_color "item_key_color" "(WHITE,BLUE,ON)"
set_color "button_active_color" "(WHITE,RED,ON)"
set_color "button_inactive_color" "(BLACK,WHITE,OFF)"
set_color "button_key_active_color" "(WHITE,RED,ON)"
set_color "button_key_inactive_color" "(BLACK,WHITE,OFF)"
set_color "button_label_active_color" "(WHITE,RED,ON)"
set_color "button_label_inactive_color" "(BLACK,WHITE,OFF)"
set_color "act_button_left_key" '""'
set_color "act_button_right_key" '""'


export DIALOGRC
export ESCDELAY=0
export NCURSES_NO_UTF8_ACS=1

if [[ ! -d "$SSID_DIR" ]]; then mkdir -p "$SSID_DIR"; fi
if [[ ! -f "$DUMMY_FILE" ]]; then
    cat << EOF > "$DUMMY_FILE"
00:1B:54:0C:D2:E5 Smooth as Buffer
00:1B:54:18:CA:47 The promised LAN
00:1B:54:21:7F:3A My Wi-Fi Is Always Right
00:1B:54:3F:11:6C Router? I Hardly Know Her!
00:1B:54:4D:16:2A The LAN of Lost Souls
00:1B:54:54:9E:01 Nacho WiFi
00:1B:54:6B:8C:12 Feeling Routy
00:1B:54:6E:22:B4 I Can Haz WiFi?
00:1B:54:88:12:DA Ask Me Out on a Data
00:1B:54:97:0A:7D The Upside Down-load
00:1B:54:9D:40:57 The LAN of the Free
00:25:9C:91:FE:14 404 Network Unavailable
18:56:80:D2:7C:A8 Dunder Mifflin
1C:B7:2C:90:5E:D1 Lord of the Pings
2C:30:33:03:7F:29 It Hurts when IP
2C:30:33:1A:55:9F Wi Oh Wi
2C:30:33:2D:4A:BC Tell my WiFi I love her
2C:30:33:4C:9A:2E Winter WonderLAN
2C:30:33:5F:C7:41 That’s One Hotspot
2C:30:33:6B:D0:11 Hotspot Time Machine
2C:30:33:7E:11:93 Gateway to Heaven
2C:30:33:8B:6E:10 Friendly Neighborhood Spider-Lan
2C:30:33:90:3C:DA Hidden Network
2C:30:33:AF:18:07 Leaky Sync
2C:30:33:CC:38:55 Bat Cave Guest Network
2C:30:33:DE:03:68 Putting in the Network
2C:F0:5D:6B:4A:CE Free Public WiFi
34:60:F9:CB:05:8E Click Here for Viruses
3C:84:6A:91:2F:B0 Bill Wi the Science Fi
40:ED:98:61:0A:BC Who What When Where WiFi
50:C7:BF:0A:9E:74 Wi-Finders Keepers
50:C7:BF:10:77:3B Keep It on The Download
50:C7:BF:12:5A:E1 WiFi so Serious?
50:C7:BF:2F:88:1B WiFi-ve More Minutes
50:C7:BF:33:61:99 Feed Me
50:C7:BF:3A:19:4F The Cake is a Lie
50:C7:BF:5D:02:AF No Wi-Fi for You!
50:C7:BF:71:0F:2C The Web of Lies
50:C7:BF:8E:34:C2 No Laughing Router
50:C7:BF:9C:2B:5E Burrito Management System
50:C7:BF:CE:90:08 Can You See Where IP?
50:C7:BF:FA:10:60 Don’t Stop Believ-LAN
58:EF:68:2A:9C:41 Silence of the LANs
5C:A6:E6:4E:88:21 Winternet is Coming
64:16:7F:AD:92:38 Blast Off Modem
6C:72:20:AF:09:31 I Believe Wi Can Fi
70:4F:57:8B:33:AD Hogwarts Great Hall Wi-Fi
84:D6:D0:7A:3C:59 Trojan Virus
90:9F:33:81:B4:F2 Abraham Linksys
9C:53:22:AF:44:08 Routers of the Lost Ark
A4:2B:8C:77:10:3E Wu-Tang LAN
A8:5B:F3:2E:19:77 Accio Internet
AC:15:A2:3D:7F:66 You’re a Wi-Fi, Harry
B8:27:EB:9C:11:73 New England Clam Router
C0:25:E9:3A:66:4D Bandwidth Together
D8:5D:4C:6F:01:92 Yoda Only Connection I Need
DC:A6:32:58:EF:04 Inigo the Modem
E0:3F:49:12:C8:6A Return of the Wi-Fi
EC:9B:F3:44:21:0A Every day I’m buffering
F0:9F:C2:0F:73:26 Not a Secret Government base
F0:9F:C2:13:6D:9C Tear Down This Firewall
F0:9F:C2:24:6E:92 The Banana Stand
F0:9F:C2:2B:FE:01 IP Frequently
F0:9F:C2:35:DB:79 Hello, is it me your’e looking 4
F0:9F:C2:4E:20:5B Wi-Find You Cute
F0:9F:C2:6A:05:F0 Drop it like it’s Hotspot
F0:9F:C2:7C:31:A8 Caught in the Interweb
F0:9F:C2:81:94:0C Pretty Fly for a WiFi
F0:9F:C2:9A:44:30 Just One Byte
EOF
fi

clear

# Initialize Interface Data
INTERFACES=($(get_interfaces))
for iface in "${INTERFACES[@]}"; do
    info=$(get_interface_info "$iface")
    IFACE_IP[$iface]=${info%|*}
    IFACE_INTERNET[$iface]=${info#*|}
done

if [[ ${#INTERFACES[@]} -eq 0 ]]; then
    dialog --colors --backtitle "$BACKTITLE" --title " Warning " --ok-label "Exit" --msgbox "No wireless interfaces detected!" 7 50
    exit 1
fi

# Auto-selection logic for interfaces
HAS_INTERNET_COUNT=0
NO_INTERNET_COUNT=0
for iface in "${INTERFACES[@]}"; do
    if [[ "${IFACE_INTERNET[$iface]}" == "YES" ]]; then
        ((HAS_INTERNET_COUNT++))
        SELECTED_INTERFACES[$iface]="off"
    else
        ((NO_INTERNET_COUNT++))
        SELECTED_INTERFACES[$iface]="on"
    fi
done

AUTO_SELECTED_IFACES=false
if [[ ${#INTERFACES[@]} -ge 2 && $HAS_INTERNET_COUNT -gt 0 && $NO_INTERNET_COUNT -gt 0 ]]; then
    AUTO_SELECTED_IFACES=true
fi

# If only one card, select it
if [[ ${#INTERFACES[@]} -eq 1 ]]; then
    SELECTED_INTERFACES[${INTERFACES[0]}]="on"
fi

# ==============================================================================
# Main Menu Loop (State Machine)
# ==============================================================================

while true; do
    COLS=$(tput cols 2>/dev/null || echo 80)
    LINES=$(tput lines 2>/dev/null || echo 24)

    case $STEP in
        1)
            options=()
            all_on=true
            for iface in "${INTERFACES[@]}"; do [[ "${SELECTED_INTERFACES[$iface]}" == "off" ]] && all_on=false && break; done
            mark="[ ]"; $all_on && mark="[X]"
            options+=("ALL" "$mark Select/Deselect All")
            options+=(" " " ")
            for iface in "${INTERFACES[@]}"; do
                mark="[ ]"; [[ "${SELECTED_INTERFACES[$iface]}" == "on" ]] && mark="[X]"
                inet_display="${IFACE_INTERNET[$iface]}"
                [[ "$inet_display" == "YES" ]] && inet_display="\Z1YES\Zn"
                status_str=$(printf "%-4s  IP: %-15s  Internet: %b" "$mark" "${IFACE_IP[$iface]}" "$inet_display")
                options+=("$iface" "$status_str")
            done
            
            DEFAULT_BTN="extra" # Toggle
            if [[ ${#INTERFACES[@]} -eq 1 ]] || [[ $NO_INTERNET_COUNT -gt 0 ]]; then
                DEFAULT_BTN="cancel" # Next
            fi

            X_OFFSET=$(( (COLS - 80) / 2 )); [[ $X_OFFSET -lt 0 ]] && X_OFFSET=0
            Y_OFFSET=$(( (LINES - 20) / 2 )); [[ $Y_OFFSET -lt 0 ]] && Y_OFFSET=0

            dialog --colors --backtitle "$BACKTITLE" \
                --begin $Y_OFFSET $X_OFFSET --title " Interface Selection " \
                --ok-label "Exit" --extra-button --extra-label "Toggle" \
                --cancel-label "Next" \
                --default-button $DEFAULT_BTN --default-item "$LAST_ITEM_IFACE" \
                --menu "Select wireless interfaces to use for Fake APs:" 20 80 12 "${options[@]}" 2>"$CHOICE_FILE"
            
            status=$?
            choice=$(cat "$CHOICE_FILE")
            log_debug "Step 1: status=$status choice='$choice'"

            case $status in
                0) cleanup ;; # Exit
                1) # Next
                    [[ "$choice" == " " ]] && continue
                    count=0
                    for iface in "${INTERFACES[@]}"; do [[ "${SELECTED_INTERFACES[$iface]}" == "on" ]] && ((count++)); done
                    
                    if [[ $count -eq 0 && -n "$choice" && "$choice" != "ALL" ]]; then
                        SELECTED_INTERFACES["$choice"]="on"
                        count=1
                        log_debug "Auto-selected focused interface: $choice"
                    fi

                    if [[ $count -gt 0 ]]; then 
                        has_internet=false
                        for iface in "${INTERFACES[@]}"; do
                            if [[ "${SELECTED_INTERFACES[$iface]}" == "on" && "${IFACE_INTERNET[$iface]}" == "YES" ]]; then has_internet=true; break; fi
                        done
                        if $has_internet; then
                            dialog --colors --backtitle "$BACKTITLE" --title " \Z1Internet Access Warning\Zn " --yesno "One or more selected interfaces have internet access.\nYou might go offline.\n\nDo you want to continue?" 10 65
                            [[ $? -ne 0 ]] && continue
                        fi
                        STEP=2
                        log_debug "Proceeding to Step 2"
                    else 
                        dialog --colors --title " Error " --msgbox "Please select at least one interface!" 6 40
                    fi
                    ;;
                3) # Toggle
                    [[ "$choice" == " " ]] && continue
                    LAST_ITEM_IFACE="$choice"
                    if [[ "$choice" == "ALL" ]]; then
                        all_now_on=true
                        for iface in "${INTERFACES[@]}"; do [[ "${SELECTED_INTERFACES[$iface]}" == "off" ]] && all_now_on=false && break; done
                        if $all_now_on; then
                            for iface in "${INTERFACES[@]}"; do SELECTED_INTERFACES[$iface]="off"; done
                        else
                            for iface in "${INTERFACES[@]}"; do SELECTED_INTERFACES[$iface]="on"; done
                        fi
                    else
                        [[ "${SELECTED_INTERFACES[$choice]}" == "on" ]] && SELECTED_INTERFACES[$choice]="off" || SELECTED_INTERFACES[$choice]="on"
                    fi ;;
                255) cleanup ;;
            esac ;;
        2)
            ssid_list=($(find "$SSID_DIR" -maxdepth 1 -type f | sort))
            options=()
            if [[ ${#SELECTED_SSIDS[@]} -eq 0 ]]; then
                 for f in "${ssid_list[@]}"; do SELECTED_SSIDS["$(basename "$f")"]="off"; done
                 if [[ ${#ssid_list[@]} -gt 0 ]]; then
                    SELECTED_SSIDS["$(basename "${ssid_list[0]}")"]="on"
                    log_debug "Auto-selected first SSID file: $(basename "${ssid_list[0]}")"
                 fi
            fi
            
            all_ssids_on=true
            for f in "${ssid_list[@]}"; do [[ "${SELECTED_SSIDS[$(basename "$f")]}" == "off" ]] && all_ssids_on=false && break; done
            mark="[ ]"; $all_ssids_on && mark="[X]"
            options+=("ALL" "$mark Select/Deselect All")
            options+=(" " " ")

            for f in "${ssid_list[@]}"; do
                bn=$(basename "$f"); lc=$(wc -l < "$f")
                mark="[ ]"; [[ "${SELECTED_SSIDS[$bn]}" == "on" ]] && mark="[X]"
                options+=("$bn" "$mark Lines: $lc")
            done

            if [[ "$LAST_ITEM_SSID" == "ALL" && ${#ssid_list[@]} -gt 0 ]]; then 
                PREVIEW_FILE=$(basename "${ssid_list[0]}")
            else 
                PREVIEW_FILE="$LAST_ITEM_SSID"
            fi
            
            if [[ -n "$PREVIEW_FILE" && -f "$SSID_DIR/$PREVIEW_FILE" ]]; then
                PREVIEW_TEXT=$(head -n 5 "$SSID_DIR/$PREVIEW_FILE" 2>/dev/null | sed -E 's/^([0-9A-Fa-f:]{12,17}|[0-9A-Fa-f]{12}) //' | while read -r line; do printf "%s\\n" "$line"; done)
            else 
                PREVIEW_TEXT="No preview available."
            fi
            
            X_OFFSET=$(( (COLS - 80) / 2 )); [[ $X_OFFSET -lt 0 ]] && X_OFFSET=0
            Y_OFFSET=$(( (LINES - 21) / 2 )); [[ $Y_OFFSET -lt 0 ]] && Y_OFFSET=0

            dialog --colors --backtitle "$BACKTITLE" \
                --begin $((Y_OFFSET + 13)) $X_OFFSET --title " Preview (First 5 SSIDs) " --infobox "$PREVIEW_TEXT" 8 80 \
                --and-widget \
                --begin $Y_OFFSET $X_OFFSET --title " SSID Category Selection " \
                --ok-label "Back" --extra-button --extra-label "Toggle" \
                --cancel-label "Next" \
                --default-button cancel --default-item "$LAST_ITEM_SSID" \
                --menu "Choose SSID lists:" 12 80 4 "${options[@]}" 2>"$CHOICE_FILE"
            
            status=$?
            choice=$(cat "$CHOICE_FILE")
            log_debug "Step 2: status=$status choice='$choice'"

            case $status in
                0) STEP=1 ;; # Back
                1) # Next
                    [[ "$choice" == " " ]] && continue
                    count=0
                    for f in "${!SELECTED_SSIDS[@]}"; do [[ "$f" != "ALL" && "${SELECTED_SSIDS[$f]}" == "on" ]] && ((count++)); done
                    
                    if [[ $count -eq 0 && -n "$choice" && "$choice" != "ALL" ]]; then
                        SELECTED_SSIDS["$choice"]="on"
                        count=1
                        log_debug "Auto-selected focused SSID file: $choice"
                    fi

                    if [[ $count -gt 0 ]]; then 
                        STEP=3
                        log_debug "Proceeding to Step 3"
                    else 
                        dialog --msgbox "Please select at least one SSID file!" 5 40
                    fi
                    ;;
                3) # Toggle
                    [[ "$choice" == " " ]] && continue
                    LAST_ITEM_SSID="$choice"
                    if [[ "$choice" == "ALL" ]]; then
                        all_now_on=true
                        for f in "${ssid_list[@]}"; do [[ "${SELECTED_SSIDS[$(basename "$f")]}" == "off" ]] && all_now_on=false && break; done
                        if $all_now_on; then
                            for f in "${ssid_list[@]}"; do SELECTED_SSIDS["$(basename "$f")"]="off"; done
                        else
                            for f in "${ssid_list[@]}"; do SELECTED_SSIDS["$(basename "$f")"]="on"; done
                        fi
                    else
                        [[ "${SELECTED_SSIDS[$choice]}" == "on" ]] && SELECTED_SSIDS[$choice]="off" || SELECTED_SSIDS[$choice]="on"
                    fi ;;
                255) STEP=1 ;;
            esac ;;
        3)
            SFILES=""; for f in "${!SELECTED_SSIDS[@]}"; do [[ "$f" != "ALL" && "${SELECTED_SSIDS[$f]}" == "on" ]] && SFILES+="$f, "; done
            SFILES=${SFILES%, }
            SIFACES=""; for iface in "${INTERFACES[@]}"; do [[ "${SELECTED_INTERFACES[$iface]}" == "on" ]] && SIFACES+="$iface, "; done
            SIFACES=${SIFACES%, }
            
            X_OFFSET=$(( (COLS - 70) / 2 )); [[ $X_OFFSET -lt 0 ]] && X_OFFSET=0
            Y_OFFSET=$(( (LINES - 12) / 2 )); [[ $Y_OFFSET -lt 0 ]] && Y_OFFSET=0

            dialog --colors --backtitle "$BACKTITLE" \
                --begin $Y_OFFSET $X_OFFSET --title " Start Flooding " \
                --yes-label "Back" --no-label "RUN" --default-button "no" \
                --yesno "Ready to flood the air with fake APs\n\nUsing the following netcards: \Z3$SIFACES\Zn\n\nSSID files: \Z3$SFILES\Zn\n\nPress RUN to start. Press Ctrl+C later to stop." 12 70
            status=$?
            log_debug "Step 3: status=$status"
            case $status in 
                0) STEP=2 ;; 
                1) break ;; 
                255) STEP=2 ;; 
            esac ;;
    esac
done

# Execution
clear
echo ""
echo -e "\e[1;34m[+] Initializing Fake AP Flooding...\e[0m"
log_debug "Initializing attack phase"

COMBINED_SSID_FILE=$(mktemp /tmp/fake_ap_ssids.XXXXXX)
for f in "${!SELECTED_SSIDS[@]}"; do
    if [[ "$f" != "ALL" && "${SELECTED_SSIDS[$f]}" == "on" ]]; then
        cat "$SSID_DIR/$f" >> "$COMBINED_SSID_FILE"
    fi
done

SUCCESS_COUNT=0
FAILED_MESSAGES=""

for iface in "${INTERFACES[@]}"; do
    if [[ "${SELECTED_INTERFACES[$iface]}" == "on" ]]; then
        TOUCHED_INTERFACES[$iface]="yes"
        nmcli device show "$iface" 2>/dev/null | grep -q "unmanaged" || (echo "[+] Setting $iface to unmanaged..."; nmcli device set "$iface" managed no >/dev/null 2>&1; IFACE_MANAGED_STATE[$iface]="managed")
        
        echo "[+] Enabling monitor mode on $iface..."
        log_debug "Enabling monitor mode on $iface"
        
        if command -v timeout &>/dev/null; then
            timeout 8 airmon-ng stop "${iface}mon" >/dev/null 2>&1
            timeout 8 airmon-ng stop "${iface}min" >/dev/null 2>&1
            if iw dev "$iface" info 2>/dev/null | grep -q "type monitor"; then
                echo "[+] Resetting $iface from monitor mode..."
                timeout 8 airmon-ng stop "$iface" >/dev/null 2>&1
            fi
        else
            airmon-ng stop "${iface}mon" >/dev/null 2>&1
            airmon-ng stop "${iface}min" >/dev/null 2>&1
            if iw dev "$iface" info 2>/dev/null | grep -q "type monitor"; then
                echo "[+] Resetting $iface from monitor mode..."
                airmon-ng stop "$iface" >/dev/null 2>&1
            fi
        fi
        
        output=$(airmon-ng start "$iface" 2>/dev/null)
        mon_iface=$(echo "$output" | grep -oP 'monitor mode enabled on \K[^)]+' | tr -d '[]' | awk '{print $1}')
        [[ -z "$mon_iface" ]] && mon_iface=$(iw dev 2>/dev/null | awk '/Interface/ {iface=$2} /type monitor/ {print iface}' | grep -E "^${iface}" | head -n 1)
        [[ -z "$mon_iface" ]] && (ip link show "${iface}mon" >/dev/null 2>&1 && mon_iface="${iface}mon" || (ip link show "${iface}min" >/dev/null 2>&1 && mon_iface="${iface}min" || mon_iface="$iface"))
        
        if [[ -z "$mon_iface" ]]; then
            if iw dev "$iface" info 2>/dev/null | grep -q "type monitor"; then mon_iface="$iface"; fi
        fi

        log_debug "Resolved monitor interface for $iface: '$mon_iface'"
        
        if [[ -z "$mon_iface" ]]; then
            msg="Could not determine monitor interface for $iface"
            echo -e "\e[1;31m[FAILED]\e[0m $msg"
            FAILED_MESSAGES+="$iface: $msg\n"
            continue
        fi

        nmcli device set "$mon_iface" managed no >/dev/null 2>&1
        echo "[+] Starting mdk4 on $mon_iface..."
        log_debug "Executing: mdk4 \"$mon_iface\" b -h -c 1 -v \"$COMBINED_SSID_FILE\""
        
        MDK_ERR_FILE=$(mktemp /tmp/mdk_err.XXXXXX)
        if [[ "$DEBUG" == "1" ]]; then
            mdk4 "$mon_iface" b -h -c 1 -v "$COMBINED_SSID_FILE" > >(tee "$MDK_ERR_FILE" | tee -a "$DEBUG_LOG") 2>&1 &
        else
            mdk4 "$mon_iface" b -h -c 1 -v "$COMBINED_SSID_FILE" > >(tee "$MDK_ERR_FILE") 2>&1 &
        fi
        pid=$!
        
        log_debug "Started mdk4 on $mon_iface (PID: $pid)"
        
        sleep 1.5
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "\e[1;32m[OK]\e[0m mdk4 started on $mon_iface"
            MDK_PIDS+=($pid)
            ((SUCCESS_COUNT++))
            log_debug "mdk4 confirmed running on $mon_iface"
        else
            err_msg=$(cat "$MDK_ERR_FILE" | tr '\n' ' ' | sed 's/  */ /g')
            [[ -z "$err_msg" ]] && err_msg="Unknown error"
            echo -e "\e[1;31m[FAILED]\e[0m mdk4 failed on $mon_iface: $err_msg"
            FAILED_MESSAGES+="$mon_iface: $err_msg\n"
            log_debug "mdk4 FAILED to start on $mon_iface: $err_msg"
        fi
        rm -f "$MDK_ERR_FILE"
    fi
done

if [[ $SUCCESS_COUNT -eq 0 ]]; then
    dialog --colors --title " Critical Failure " --msgbox "Failed to start any mdk4 processes!\n\nErrors:\n$FAILED_MESSAGES" 15 70
    log_debug "All mdk4 instances failed. Exiting."
    cleanup
fi

echo -e "\n\e[1;34m[+] Attack active with $SUCCESS_COUNT interface(s).\e[0m"
echo "[+] Press Ctrl+C to stop the attack and restore network settings."
while true; do sleep 1; done
