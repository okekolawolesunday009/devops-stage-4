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
    create_ns <vpc_name> <ns_name> <public_subnet | private_subnet> <public|private> - create a new namespace in a VPC
    delete_ns <ns_name> - delete a namespace
    peer_vpcs <vpc_name1> <vpc_name2> - peer two VPCs
    unpeer_vpcs <vpc_name1> <vpc_name2> - (not implemented)
    list           - (not implemented)
    help           - show this help message
    cleanup_all    - cleanup all VPCs and namespaces
EOF
    exit 1
}

# Create a VPC (Linux bridge)
create_vpc() {
    local name=$1
    local cidr_block=$2
    local br="vpc-$name-br"

    # Create bridge if it doesn't exist
    run ip link show "$br" >/dev/null 2>&1 || run ip link add name "$br" type bridge

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

    echo "VPC '$name' created with gateway '$gateway_cidr' (bridge: '$br')"
}

# Delete a VPC
delete_vpc() {
    local name=$1
    local br="vpc-$name-br"

    run ip link set "$br" down 2>/dev/null || true
    run ip link delete "$br" 2>/dev/null || true

    echo "VPC '$name' deleted (bridge: '$br')"
}

# Create namespace and attach to VPC
create_ns() {
    local vpc=$1
    local namespace=$2
    local ipcidr=$3
    local gateway_cidr=$4
    local dev="veth-$namespace"
    local peer="veth-$namespace-br"
    local br=$5
    local subnet_type=$6  # 'public' or 'private'

    # Create namespace
    run ip netns add "$namespace"
    echo "Namespace '$namespace' created"

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

    # Enable NAT if this is a public subnet
    if [ "$subnet_type" == "public" ]; then
    # Get the public IP address of the external interface (eth0)
        public_ip=$(ip -o -4 addr show dev eth0 | awk '{print $4}' | cut -d'/' -f1)

        if [ -n "$public_ip" ]; then
            # Check if the SNAT rule already exists, otherwise add it
            iptables -t nat -C POSTROUTING -s "$ipcidr" -o eth0 -j SNAT --to-source "$public_ip" 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s "$ipcidr" -o eth0 -j SNAT --to-source "$public_ip"

            echo "Static SNAT enabled for public subnet $namespace ($ipcidr → $public_ip)"
        else
            echo "Error: Could not determine public IP for eth0" >&2
        fi
    fi

}

# Delete namespace
delete_ns() {
    local namespace=$1
    run ip netns delete "$namespace" 2>/dev/null || true

    # Delete any associated veth interfaces
    for p in $(ip -o link show | awk -F ': ' '{print $2}' | grep -E "veth-$namespace-br|veth-$namespace$" || true); do
        run ip link delete "$p" 2>/dev/null || true
    done
    echo "Namespace '$namespace' deleted"
}

# Peer two VPCs
peer_vpcs() {
    local vpc1=$1
    local vpc2=$2
    shift 2
    local allowed_cidrs=("$@")
    local br=$3
    

    if [ "$vpc1" == "$vpc2" ]; then
        echo "Error: VPC cannot peer with itself"
        return 1
    fi

    run ip link add name "veth-$vpc1" type veth peer name "veth-$vpc1-br"
    run ip link add name "veth-$vpc2" type veth peer name "veth-$vpc2-br"
    run ip link set "veth-$vpc1" master "$br"
    run ip link set "veth-$vpc2" master "$br"
    run ip link set "veth-$vpc1" up
    run ip link set "veth-$vpc2" up

    # Add static routes for allowed CIDRs in all namespaces of both VPCs
    for ns in $(ip netns list | awk -F ': ' '{print $1}'); do
        ns_vpc=$(echo $ns | cut -d'-' -f1)
        if [ "$ns_vpc" == "$vpc1" ]; then
            for cidr in "${allowed_cidrs[@]}"; do
                ip netns exec "$ns" ip route add "$cidr" dev "veth-$vpc1-$vpc2" || true
            done
        elif [ "$ns_vpc" == "$vpc2" ]; then
            for cidr in "${allowed_cidrs[@]}"; do
                ip netns exec "$ns" ip route add "$cidr" dev "veth-$vpc2-$vpc1" || true
            done
        fi
    done

    echo "VPC '$vpc1' and '$vpc2' are peered ($br)"
    if [ ${#allowed_cidrs[@]} -gt 0 ]; then
        echo "Allowed cross-VPC CIDRs: ${allowed_cidrs[*]}"
    fi
}


unpeer_vpcs() {
    local vpc1=$1
    local vpc2=$2
    local br=$3
        
    run ip link delete "veth-$vpc1" 2>/dev/null || true
    run ip link delete "veth-$vpc2" 2>/dev/null || true
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
    for br in $(ip link show | awk -F ': ' '{print $2}' | grep -E 'vpc-.*-br' || true); do
        run ip link set "$br" down 2>/dev/null || true
        run ip link delete "$br" 2>/dev/null || true
    done

    # Flush iptables
    run iptables -F
    run iptables -t nat -F

    echo "All VPCs and namespaces cleaned up"
}

add_sg(){
    local vpc=$1
    local ns=$2
    local cidr=$3
    local policy_file=$4

    rules=$(jq -c ".[] | select(.subnet == \"$cidr\") | .ingress[]" "$policy_file")

    for rule in $rules; do
    port=$(echo $rule | jq -r '.port')
    proto=$(echo $rule | jq -r '.protocol')
    action=$(echo $rule | jq -r '.action')
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

    rules=$(jq -c ".[] | select(.subnet == \"$cidr\") | .ingress[]" "$policy_file")

    for rule in $rules; do
    port=$(echo $rule | jq -r '.port')
    proto=$(echo $rule | jq -r '.protocol')
    action=$(echo $rule | jq -r '.action')
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
if [ $# -lt 1 ]; then usage; fi
cmd=$1; shift
case "$cmd" in
    create_vpc) [ $# -ne 2 ] && usage; create_vpc "$1" "$2" ;;
    delete_vpc) [ $# -ne 1 ] && usage; delete_vpc "$1" ;;
    create_ns) [ $# -ne 6 ] && usage; create_ns "$1" "$2" "$3" "$4" "$5" "$6" ;;
    delete_ns) [ $# -ne 1 ] && usage; delete_ns "$1" ;;
    peer_vpcs) [ $# -ne 2 ] && usage; peer_vpcs "$1" "$2" ;;
    unpeer_vpcs) [ $# -ne 2 ] && usage; unpeer_vpcs "$1" "$2" ;;
    list) echo "Listing not implemented"; ;;
    cleanup_all) cleanup_all ;;
    help) usage ;;
    *) usage ;;
esac