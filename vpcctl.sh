#!/bin/bash
set -euxo pipefail  

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root." >&2
  exit 1
fi


echo "**********************************************************************"
echo "vpcctl - tiny VPC manager using Linux bridges, netns, veth, iptables"
echo "**********************************************************************"

# Helper function to show commands before running
run() {
    echo "+ $*"
    "$@"
}

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
        echo "Error: Bridge '$br' already exists" >&2
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

    echo "[SUCCESS] VPC '$name' created with CIDR '$cidr_block' (bridge: '$br')"
}

# Delete a VPC
delete_vpc() {
    local name=$1
    local br="vpc-$name-br"

    # Check if bridge exists
    if ! ip link show "$br" >/dev/null 2>&1; then
        echo "Error: Bridge '$br' does not exist" >&2
        return 1
    fi

    run ip link set "$br" down 2>/dev/null || true
    run ip link delete "$br" 2>/dev/null || true

    echo "[SUCCESS] VPC '$name' deleted (bridge: '$br')"
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
        echo "Error: Namespace '$namespace' already exists" >&2
        return 1
    fi

    # Create namespace
    run ip netns add "$namespace"
    echo "[SUCCESS] Namespace '$namespace' created and attached to bridge '$br' with IP '$ipcidr'"

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
    run ip netns exec "$namespace" ip route add default via "$gateway_ip" dev "$dev"


    
  

    # Enable NAT if nat_enabled is true
    if [ "$nat_enabled" == "true" ]; then
        public_ip=$(ip -o -4 addr show dev "$br" | awk '{print $4}' | cut -d'/' -f1)
        if [ -n "$public_ip" ]; then
            iptables -t nat -C POSTROUTING -s "$ipcidr" -o "$br" -j SNAT --to-source "$public_ip" 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s "$ipcidr" -o "$br" -j SNAT --to-source "$public_ip"
            echo "Static SNAT enabled for $namespace ($ipcidr → $public_ip)"
        else
            echo "Error: Could not determine public IP for $internet_interface" >&2
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
    echo "[SUCCESS] Namespace '$namespace' deleted and all associated interfaces removed."
}





# Peer two VPCs with CIDR restrictions
peer_vpcs() {
    local vpc1=${VPC_NAME:-$1}
    local vpc2=$2
    local cidr1=$3
    local cidr2=$4
    local br1="vpc-$vpc1-br"
    local br2="vpc-$vpc2-br"
    local veth1="veth-$vpc1-$vpc2"
    local veth2="veth-$vpc2-$vpc1"

    if [ "$vpc1" == "$vpc2" ]; then 
        echo "Error: Cannot peer a VPC with itself" >&2
        return 1
    fi

    # Check if bridges exist
    if ! ip link show "$br1" >/dev/null 2>&1; then
        echo "Error: Bridge '$br1' does not exist" >&2
        return 1
    fi
    if ! ip link show "$br2" >/dev/null 2>&1; then
        echo "Error: Bridge '$br2' does not exist" >&2
        return 1
    fi

    # Create veth pair
    run ip link add "$veth1" type veth peer name "$veth2"
    run ip link set "$veth1" master "$br1"
    run ip link set "$veth2" master "$br2"
    run ip link set "$veth1" up
    run ip link set "$veth2" up

    # Restrict traffic to allowed CIDRs only
    iptables -A FORWARD -i "$veth1" -s "$cidr1" -d "$cidr2" -j ACCEPT
    iptables -A FORWARD -i "$veth2" -s "$cidr2" -d "$cidr1" -j ACCEPT
    iptables -A FORWARD -i "$veth1" -j DROP
    iptables -A FORWARD -i "$veth2" -j DROP

    echo "VPC '$vpc1' and '$vpc2' are now peered via $veth1 <-> $veth2 (allowed: $cidr1 <-> $cidr2)"
}

unpeer_ns() {
    local vpc_ns1=${NS1:-$1}
    local vpc_ns2=${NS2:-$2}
    local br=${BR1:-$3}
    local cidr1=$4
    local cidr2=$5

    run ip link delete "veth-$vpc_ns1" 2>/dev/null || true
    run ip link delete "veth-$vpc_ns2" 2>/dev/null || true
    run ip link down "$br" 2>/dev/null || true
    run ip link delete "$br" 2>/dev/null || true
}

# List all VPCs and namespaces
list_state() {
    echo "Listing all VPCs and namespaces"
    ip netns list
    ip link show | awk -F ': ' '{print $2}' | grep -E 'vpc-.*-br'
}
# Cleanup all VPCs and namespaces
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
      # Flags: -v <vpc1> -w <vpc2> -c <cidr1> -d <cidr2>
      VPC_NAME=""; VPC2=""; CIDR_BLOCK=""; CIDR2=""
      while getopts "v:w:c:d:h" opt; do
        case $opt in
          v) VPC_NAME="$OPTARG";;
          w) VPC2="$OPTARG";;
          c) CIDR_BLOCK="$OPTARG";;
          d) CIDR2="$OPTARG";;
          h) usage;;
        esac
      done
      shift $((OPTIND-1))
      peer_vpcs "${VPC_NAME:-$1}" "${VPC2:-$2}" "${CIDR_BLOCK:-$3}" "${CIDR2:-$4}"
      ;;
    unpeer_vpcs)
      # Flags: -v <vpc1> -w <vpc2> -c <cidr1> -d <cidr2>
      VPC_NAME=""; VPC2=""; CIDR_BLOCK=""; CIDR2=""
      while getopts "v:w:c:d:h" opt; do
        case $opt in
          v) VPC_NAME="$OPTARG";;
          w) VPC2="$OPTARG";;
          c) CIDR_BLOCK="$OPTARG";;
          d) CIDR2="$OPTARG";;
          h) usage;;
        esac
      done
      shift $((OPTIND-1))
      unpeer_vpcs "${VPC_NAME:-$1}" "${VPC2:-$2}" "${CIDR_BLOCK:-$3}" "${CIDR2:-$4}"
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