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
    create_vpc <vpc_name> <gateway_cidr> - create a new VPC
    delete_vpc <vpc_name> - delete a VPC
    create_ns <vpc_name> <ns_name> <ip_cidr> <gateway_cidr> - create a new namespace in a VPC
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
    local gateway_cidr=$2
    local br="vpc-$name-br"

    # Create bridge if it doesn't exist
    run ip link show "$br" >/dev/null 2>&1 || run ip link add name "$br" type bridge

    # Assign IP if not already assigned
    if ! ip -c addr show dev "$br" | grep "$gateway_cidr"; then 
        run ip addr add "$gateway_cidr" dev "$br"
    fi

    run ip link set "$br" up
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
    local br1="vpc-$vpc1-br"
    local br2="vpc-$vpc2-br"

    if [ "$vpc1" == "$vpc2" ]; then
        echo "Error: VPC cannot peer with itself"
        return 1
    fi

    run ip link add name "veth-$vpc1-$vpc2" type veth peer name "veth-$vpc2-$vpc1"
    run ip link set "veth-$vpc1-$vpc2" master "$br1"
    run ip link set "veth-$vpc2-$vpc1" master "$br2"
    run ip link set "veth-$vpc1-$vpc2" up
    run ip link set "veth-$vpc2-$vpc1" up

    echo "VPC '$vpc1' and '$vpc2' are peered ($br1 <-> $br2)"
    echo "Add SG rules to control inter-VPC traffic if needed"
}

# Cleanup all VPCs and namespaces
clean_up() {
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

# Command parsing
if [ $# -lt 1 ]; then usage; fi
cmd=$1; shift
case "$cmd" in
    create_vpc) [ $# -ne 2 ] && usage; create_vpc "$1" "$2" ;;
    delete_vpc) [ $# -ne 1 ] && usage; delete_vpc "$1" ;;
    create_ns) [ $# -ne 5 ] && usage; create_ns "$1" "$2" "$3" "$4" "$5" ;;
    delete_ns) [ $# -ne 1 ] && usage; delete_ns "$1" ;;
    peer_vpcs) [ $# -ne 2 ] && usage; peer_vpcs "$1" "$2" ;;
    unpeer_vpcs) [ $# -ne 2 ] && usage; echo "Not implemented yet"; ;;
    list) echo "Listing not implemented"; ;;
    cleanup_all) clean_up ;;
    help) usage ;;
    *) usage ;;
esac
