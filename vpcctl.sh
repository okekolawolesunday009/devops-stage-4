#!/bin/bash
set -euxo pipefail  

# Logging configuration
LOG_DIR="${LOG_DIR:-/var/log/vpcctl}"
LOG_FILE="$LOG_DIR/vpcctl_$(date +'%Y%m%d').log"
LOG_LEVEL=${LOG_LEVEL:-INFO}  # Can be: DEBUG, INFO, WARNING, ERROR
LOG_MAX_SIZE=${LOG_MAX_SIZE:-10}  # Max log file size in MB
LOG_MAX_FILES=${LOG_MAX_FILES:-7}  # Number of log files to keep

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Log rotation function
rotate_logs() {
    # Rotate if log file exists and is larger than max size
    if [ -f "$LOG_FILE" ]; then
        local size_mb=$(du -m "$LOG_FILE" | cut -f1)
        if [ "$size_mb" -ge "$LOG_MAX_SIZE" ]; then
            # Rotate logs
            for i in $(seq $((LOG_MAX_FILES-1)) -1 1); do
                if [ -f "${LOG_FILE}.${i}.gz" ]; then
                    mv -f "${LOG_FILE}.${i}.gz" "${LOG_FILE}.$((i+1)).gz" 2>/dev/null || true
                fi
            done
            # Compress current log
            gzip -c "$LOG_FILE" > "${LOG_FILE}.1.gz" 2>/dev/null || true
            > "$LOG_FILE"  # Truncate log file
        fi
    fi
}

# Logging function
log() {
    local level=$1
    local message="${*:2}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local script_name=$(basename "$0")
    local pid=$$
    
    # Define log levels with colors
    declare -A levels=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)
    declare -A colors=([DEBUG]='\033[0;36m' [INFO]='\033[0;32m' 
                      [WARNING]='\033[1;33m' [ERROR]='\033[1;31m')
    local reset='\033[0m'
    
    local log_level_num=${levels[$LOG_LEVEL]:-1}
    local msg_level_num=${levels[$level]:-1}
    
    # Only log if message level is at or above the current log level
    if [ $msg_level_num -ge $log_level_num ]; then
        # Format: [timestamp] [level] [script:line] [function] message
        local log_entry="[$timestamp] [$level] [${script_name}:${BASH_LINENO[1]}] [${FUNCNAME[2]:-main}] $message"
        
        # Write to log file
        mkdir -p "$LOG_DIR"
        echo "$log_entry" >> "$LOG_FILE"
        
        # Color output to console
        if [ -t 1 ]; then
            echo -e "${colors[$level]}$log_entry${reset}"
        else
            echo "$log_entry"
        fi
    fi
    
    # Rotate logs if needed
    [ $level = "INFO" ] && rotate_logs
}

# Helper to log command execution
run() {
    log DEBUG "Executing: $*"
    if "$@"; then
        log DEBUG "Command succeeded: $*"
        return 0
    else
        local status=$?
        log ERROR "Command failed with status $status: $*"
        return $status
    fi
}

if [ "$EUID" -ne 0 ]; then
    log ERROR "This script must be run as root."
    exit 1
fi

log INFO "**********************************************************************"
log INFO "vpcctl - tiny VPC manager using Linux bridges, netns, veth, iptables"
log INFO "**********************************************************************"

# run() is now defined at the top with logging

# Usage instructions
usage() {
    cat <<EOF
vpcctl - manage Linux VPC

Usage: vpcctl <command>

Commands:
    create_vpc <vpc_name> <cidr_block> - create a new VPC
    delete_vpc <vpc_name> - delete a VPC
    create_ns <vpc_name> <ns_name> <ip_cidr> <gateway_cidr> <bridge> <public|private> <nat_enabled> - create a new namespace in a VPC
    delete_ns <ns_name> - delete a namespace
    peer_vpcs <vpc_name1> <vpc_name2> <bridge> - peer two VPCs
    help           - show this help message
    cleanup_all    - cleanup all VPCs and namespaces
EOF
    exit 1
}

# Load environment variables
set -a
[ -f .env ] && . .env
set +a



# Create a VPC (Linux bridge)
create_vpc() {
    local name=${VPC_NAME:-$1}
    local cidr_block=${CIDR_BLOCK:-$2}
    local br="vpc-$name-br"

    # Check if bridge already exists
    if ip link show "$br" >/dev/null 2>&1; then
        log ERROR "Bridge '$br' already exists"
        return 1
    fi

    # Create bridge if it doesn't exist
    run ip link add name "$br" type bridge

    # Assign IP if not already assigned
    if ! ip -c addr show dev "$br" | grep "$cidr_block"; then 
        run ip addr add "$cidr_block" dev "$br"
    fi

    run ip link set "$br" up

    # Enable IP forwarding (idempotent)
    sysctl -w net.ipv4.ip_forward=1

    # Set up NAT for this bridge (for public subnets)
    # The user must specify which subnets are public when creating namespaces.
    # Example usage: create_ns <vpc> <ns> <ip_cidr> <gateway_cidr> <bridge> <public|private>

    log INFO "VPC '$name' created with CIDR '$cidr_block' (bridge: '$br')"
}

# Delete a VPC
delete_vpc() {
    local name=$1
    local br="vpc-$name-br"

    # Check if bridge exists
    if ! ip link show "$br" >/dev/null 2>&1; then
        log ERROR "Bridge '$br' does not exist"
        return 1
    fi

    run ip link set "$br" down 2>/dev/null || true
    run ip link delete "$br" 2>/dev/null || true

    log INFO "VPC '$name' deleted (bridge: '$br')"
}

# Create namespace and attach to VPC
create_ns() {
    local vpc=${VPC_NAME:-$1}
    local namespace=${NS_NAME:-$2}
    local ipcidr=${CIDR_BLOCK:-$3}
    local gateway_cidr=${GW1:-$4}
    local dev="veth-$namespace"
    local peer="veth-$namespace-br"
    local br=${BR1:-$5}
    local subnet_type=${SUBNET_TYPE:-$6}  # 'public' or 'private'
    local nat_enabled=${NAT_ENABLED:-$7}
    local internet_interface=${INTERNET_INTERFACE:-$8}

    # Check if namespace already exists
    if ip netns list | grep -qw "$namespace"; then
        log ERROR "Namespace '$namespace' already exists"
        return 1
    fi

    # Create namespace
    run ip netns add "$namespace"
    log INFO "Namespace '$namespace' created and attached to bridge '$br' with IP '$ipcidr'"

    # Create veth pair
    run ip link add "$dev" type veth peer name "$peer"

    # Move veth to namespace
    run ip link set "$dev" netns "$namespace"

    # Attach peer to bridge
    run ip link set "$peer" master "$br"
    run ip link set "$peer" up

    # Assign IP inside namespace
    run ip netns exec "$namespace" ip addr add "$ipcidr" dev "$dev"
    run ip netns exec "$namespace" ip link set "$dev" up
    run ip netns exec "$namespace" ip link set lo up

    # Set default route
    local gateway_ip=$(echo "$gateway_cidr" | cut -d'/' -f1)
    log INFO "Default route set for $namespace ($ipcidr → $gateway_ip)"
    run ip netns exec "$namespace" ip route add default via "$gateway_ip" dev "$dev"


    log INFO "Namespace '$namespace' created and attached to bridge '$br' with IP '$ipcidr'"
  

    # Enable NAT if nat_enabled is true
    if [ "$nat_enabled" == "true" ]; then
        public_ip=$(ip -o -4 addr show dev "$br" | awk '{print $4}' | cut -d'/' -f1)
        if [ -n "$public_ip" ]; then
            iptables -t nat -C POSTROUTING -s "$ipcidr" -o "$br" -j SNAT --to-source "$public_ip" 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s "$ipcidr" -o "$br" -j SNAT --to-source "$public_ip"
            log INFO "Static SNAT enabled for $namespace ($ipcidr → $public_ip)"
        else
            log ERROR "Could not determine public IP for $internet_interface"
        fi
    fi

}

# Delete namespace
delete_ns() {
    local namespace=$1

    # Remove NAT rule for this namespace
    ipcidr=$(ip netns exec "$namespace" ip -o -4 addr show | awk '{print $4}' | head -n1)
    br=$(ip netns exec "$namespace" ip link show | awk -F ': ' '{print $2}' | grep -E 'vpc-.*-br' | head -n1)       
    public_ip=$(ip -o -4 addr show dev "$br" | awk '{print $4}' | cut -d'/' -f1)
    if [ -n "$ipcidr" ] && [ -n "$public_ip" ]; then
        iptables -t nat -D POSTROUTING -s "$ipcidr" -o "$br" -j SNAT --to-source "$public_ip" 2>/dev/null || true
    fi

    run ip netns delete "$namespace" 2>/dev/null || true

    # Delete any associated veth interfaces
    for p in $(ip -o link show | awk -F ': ' '{print $2}' | grep -E "veth-$namespace-br|veth-$namespace$" || true); do
        run ip link delete "$p" 2>/dev/null || true
    done
    log INFO "Namespace '$namespace' deleted and all associated interfaces removed."
}





# Peer two VPCs with CIDR restrictions
peer_vpcs() {
    local vpc1=$1
    local vpc2=$2
    local cidr1=$3       # CIDR of VPC1
    local cidr2=$4       # CIDR of VPC2
    local gw1=$5         # Gateway inside VPC1
    local gw2=$6         # Gateway inside VPC2

    # sanity check
    if [ "$vpc1" == "$vpc2" ]; then
        log ERROR "Cannot peer a VPC with itself"
        return 1
    fi

    log INFO "Peering $vpc1 ($cidr1) <-> $vpc2 ($cidr2)"    

    # Add routes so each namespace can reach the other’s subnet
    run ip netns exec "$vpc1" ip route add "$cidr2" via "$gw1"
    run ip netns exec "$vpc2" ip route add "$cidr1" via "$gw2"

    # Add iptables FORWARD rules (host level)
    run iptables -A FORWARD -s "$cidr1" -d "$cidr2" -j ACCEPT
    run iptables -A FORWARD -s "$cidr2" -d "$cidr1" -j ACCEPT



    echo "✅ VPCs '$vpc1' and '$vpc2' are now peered (allowed: $cidr1 <-> $cidr2)"
}


unpeer_vpcs() {
    local vpc1=$1
    local vpc2=$2
    local cidr1=$3
    local cidr2=$4
    local gw1=$5
    local gw2=$6

    echo "🔌 Unpeering $vpc1 <-> $vpc2"

    # Remove routes
    run ip netns exec "$vpc1" ip route del "$cidr2" 2>/dev/null || true
    run ip netns exec "$vpc2" ip route del "$cidr1" 2>/dev/null || true

    # Remove iptables rules
    run iptables -D FORWARD -s "$cidr1" -d "$cidr2" -j ACCEPT 2>/dev/null || true
    run iptables -D FORWARD -s "$cidr2" -d "$cidr1" -j ACCEPT 2>/dev/null || true

    echo "✅ Unpeering complete between $vpc1 and $vpc2"
}

cleanup_all() {
    echo "Cleaning up all VPCs and namespaces"
    read -p "Proceed with caution (y/n)? " ans
    [ "${ans,,}" == "y" ] || return 1

    # Delete namespaces
    for ns in $(ip netns list | awk -F ': ' '{print $1}' || true); do
        run ip netns delete "$ns" 2>/dev/null || true
    done

    # Delete bridges
    for br in $(ip link show | awk -F ': ' '{print $2}' | grep -E '.*-br' || true); do
        run ip link set "$br" down 2>/dev/null || true
        run ip link delete "$br" 2>/dev/null || true
    done

    # Flush iptables
    run iptables -F
    run iptables -t nat -F

    echo "[CLEANUP COMPLETE] All VPCs, namespaces, and associated resources have been removed."
}

# add_sg and remove_sg retain positional args for simplicity
add_sg(){
    local vpc=$1
    local ns=$2
    local cidr=$3
    local policy_file=$4
    local apply=$5  # -a flag (true/false), currently not used but accepted

    rules=$(awk -v cidr="$cidr" 'BEGIN{RS="{";FS=","} /subnet/ && $0 ~ cidr {for(i=1;i<=NF;i++){if($i~"ingress"){gsub(/\[|\]|}/,"",$i); print $i}}}' "$policy_file")

    for rule in $rules; do
    port=$(echo "$rule" | grep -o '"port"[ ]*:[ ]*[^,}]*' | cut -d: -f2 | tr -d ' "')
    proto=$(echo "$rule" | grep -o '"protocol"[ ]*:[ ]*[^,}]*' | cut -d: -f2 | tr -d ' "')
    action=$(echo "$rule" | grep -o '"action"[ ]*:[ ]*[^,}]*' | cut -d: -f2 | tr -d ' "')
    if [ "$action" == "allow" ]; then
        ip netns exec "$ns" iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || \
        ip netns exec "$ns" iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT
    elif [ "$action" == "deny" ]; then
        ip netns exec "$ns" iptables -C INPUT -p "$proto" --dport "$port" -j DROP 2>/dev/null || \
        ip netns exec "$ns" iptables -A INPUT -p "$proto" --dport "$port" -j DROP
    fi
    done

}

remove_sg(){
    local vpc=$1
    local ns=$2
    local cidr=$3
    local policy_file=$4
    local apply=$5  # -a flag (true/false), currently not used but accepted

    rules=$(awk -v cidr="$cidr" 'BEGIN{RS="{";FS=","} /subnet/ && $0 ~ cidr {for(i=1;i<=NF;i++){if($i~"ingress"){gsub(/\[|\]|}/,"",$i); print $i}}}' "$policy_file")

    for rule in $rules; do
    port=$(echo "$rule" | grep -o '"port"[ ]*:[ ]*[^,}]*' | cut -d: -f2 | tr -d ' "')
    proto=$(echo "$rule" | grep -o '"protocol"[ ]*:[ ]*[^,}]*' | cut -d: -f2 | tr -d ' "')
    action=$(echo "$rule" | grep -o '"action"[ ]*:[ ]*[^,}]*' | cut -d: -f2 | tr -d ' "')
    if [ "$action" == "allow" ]; then
        ip netns exec "$ns" iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || \
        ip netns exec "$ns" iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT
    elif [ "$action" == "deny" ]; then
        ip netns exec "$ns" iptables -C INPUT -p "$proto" --dport "$port" -j DROP 2>/dev/null || \
        ip netns exec "$ns" iptables -D INPUT -p "$proto" --dport "$port" -j DROP
    fi
    done
}   

# Command parsing
# Check required commands
for cmd in ip iptables awk grep cut sysctl; do
    command -v $cmd >/dev/null 2>&1 || { echo "$cmd is required but not installed. Aborting." >&2; exit 1; }
done

if [ $# -lt 1 ]; then usage; fi
cmd=$1; shift
case "$cmd" in
    create_vpc)
      # Flags: -v <vpc_name> -c <cidr_block>
      VPC_NAME=""; CIDR_BLOCK=""
      while getopts "v:c:h" opt; do
        case $opt in
          v) VPC_NAME="$OPTARG";;
          c) CIDR_BLOCK="$OPTARG";;
          h) usage;;
        esac
      done
      shift $((OPTIND-1))
      create_vpc "${VPC_NAME:-$1}" "${CIDR_BLOCK:-$2}"
      ;;
    delete_vpc) [ $# -ne 1 ] && usage; delete_vpc "$1" ;;
    create_ns)
      # Flags: -v <vpc_name> -n <namespace> -c <ipcidr> -g <gateway_cidr> -b <bridge> -t <public|private> -a <nat_enabled> -i <internet_interface>
      VPC_NAME=""; NS_NAME=""; CIDR_BLOCK=""; GW1=""; BR1=""; SUBNET_TYPE=""; NAT_ENABLED=""; INTERNET_INTERFACE=""
      while getopts "v:n:c:g:b:t:a:i:h" opt; do
        case $opt in
          v) VPC_NAME="$OPTARG";;
          n) NS_NAME="$OPTARG";;
          c) CIDR_BLOCK="$OPTARG";;
          g) GW1="$OPTARG";;
          b) BR1="$OPTARG";;
          t) SUBNET_TYPE="$OPTARG";;
          a) NAT_ENABLED="$OPTARG";;
          i) INTERNET_INTERFACE="$OPTARG";;
          h) usage;;
        esac
      done
      shift $((OPTIND-1))
      create_ns "${VPC_NAME:-$1}" "${NS_NAME:-$2}" "${CIDR_BLOCK:-$3}" "${GW1:-$4}" "${BR1:-$5}" "${SUBNET_TYPE:-$6}" "${NAT_ENABLED:-$7}" "${INTERNET_INTERFACE:-$8}"
      ;;
    delete_ns) [ $# -ne 1 ] && usage; delete_ns "$1" ;;
    peer_vpcs)
      # Flags: -v <vpc1> -w <vpc2> -c <cidr1> -d <cidr2> -g <gw1> -h <gw2>
      VPC_NAME=""; VPC2=""; CIDR_BLOCK_1=""; CIDR_BLOCK_2=""; GW_1=""; GW_2=""
      while getopts "v:w:c:d:g:h:i" opt; do
        case $opt in
          v) VPC_NAME="$OPTARG";;
          w) VPC2="$OPTARG";;
          c) CIDR_BLOCK_1="$OPTARG";;
          d) CIDR_BLOCK_2="$OPTARG";;
          g) GW_1="$OPTARG";;
          h) GW_2="$OPTARG";;
          i) usage;;
        esac
      done
      shift $((OPTIND-1))
      peer_vpcs "${VPC_NAME:-$1}" "${VPC2:-$2}" "${CIDR_BLOCK_1:-$3}" "${CIDR_BLOCK_2:-$4}" "${GW_1:-$5}" "${GW_2:-$6}"
      ;;
    unpeer_vpcs)
      # Flags: -v <vpc1> -w <vpc2> -c <cidr1> -d <cidr2> -g <gw1> -h <gw2>
      VPC_NAME=""; VPC2=""; CIDR_BLOCK_1=""; CIDR_BLOCK_2=""; GW_1=""; GW_2=""
      while getopts "v:w:c:d:g:h:i" opt; do
        case $opt in
          v) VPC_NAME="$OPTARG";;
          w) VPC2="$OPTARG";;
          c) CIDR_BLOCK_1="$OPTARG";;
          d) CIDR_BLOCK_2="$OPTARG";;
          g) GW_1="$OPTARG";;
          h) GW_2="$OPTARG";;
          i) usage;;
        esac
      done
      shift $((OPTIND-1))
      unpeer_vpcs "${VPC_NAME:-$1}" "${VPC2:-$2}" "${CIDR_BLOCK_1:-$3}" "${CIDR_BLOCK_2:-$4}" "${GW_1:-$5}" "${GW_2:-$6}"
      ;;
    cleanup_all) cleanup_all ;;
    add_sg)
      # Flags: -v <vpc_name> -n <namespace> -c <subnet_cidr> -p <policy_file> -a <apply>
      VPC_NAME=""; NS_NAME=""; CIDR_BLOCK=""; POLICY_FILE=""; APPLY=""
      while getopts "v:n:c:p:a:h" opt; do
        case $opt in
          v) VPC_NAME="$OPTARG";;
          n) NS_NAME="$OPTARG";;
          c) CIDR_BLOCK="$OPTARG";;
          p) POLICY_FILE="$OPTARG";;
          a) APPLY="$OPTARG";;
          h) usage;;
        esac
      done
      shift $((OPTIND-1))
      add_sg "${VPC_NAME:-$1}" "${NS_NAME:-$2}" "${CIDR_BLOCK:-$3}" "${POLICY_FILE:-$4}" "${APPLY:-$5}"
      ;;
    remove_sg)
      # Flags: -v <vpc_name> -n <namespace> -c <subnet_cidr> -p <policy_file> -a <apply>
      VPC_NAME=""; NS_NAME=""; CIDR_BLOCK=""; POLICY_FILE=""; APPLY=""
      while getopts "v:n:c:p:a:h" opt; do
        case $opt in
          v) VPC_NAME="$OPTARG";;
          n) NS_NAME="$OPTARG";;
          c) CIDR_BLOCK="$OPTARG";;
          p) POLICY_FILE="$OPTARG";;
          a) APPLY="$OPTARG";;
          h) usage;;
        esac
      done
      shift $((OPTIND-1))
      remove_sg "${VPC_NAME:-$1}" "${NS_NAME:-$2}" "${CIDR_BLOCK:-$3}" "${POLICY_FILE:-$4}" "${APPLY:-$5}"
      ;;
    help) usage ;;
    *) usage ;;
esac