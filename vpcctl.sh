#!/bin/bash
set euxo -pipefail  

echo "**********************************************************************"
echo "vpcctl - tiny VPC manager using linux bridges, netns, veth, iptables"
echo "**********************************************************************"


run () { echo "+ $*"; "$@" }

usage () {
    cat <<EOF
    vpcctl - manage linux vpc

    Usage: vpcctl <command>

    Commands:
        create_vpc <vpc_name> - create a new vpc
        delete_vpc <vpc_name> - delete a vpc
        create-ns <ns_name> - create a new namespace
        delete-ns <ns_name> - delete a namespace
        peer vpcs <vpc_name> <vpc2_name> - peer a namespace to a vpc
        unpeer vpcs <vpc_name> <vpc2_name> - unpeer a namespace from a vpc

        list           - list all vpcs
        help           - show this help message
        cleanup-all    - cleanup all vpcs
EOF
    exit 1
}


create_vpc() {
    local name=$1
    local gateway_cidr=$2
    
    local br="vpc-$name-br"

    #show existing 

    run ip link show "$br" >/dev/null 2>&1 || run ip link add name "$br" type bridge
    
    if ! ip -c addr show dev "$br" | grep "$gateway_cidr"; then 
        run ip addr add "$gateway_cidr" dev "$br" || true
    fi
    
    run ip link set "$br" up || true

    echo "VPC '$name' created with gateway '$gateway_cidr' and 'br '$br'"
}

delete_vpc() {
    local name=$1
    local br="vpc-$name-br"

    run ip link set "$br" down  2>/dev/null || true
    run ip link delete "$br" 2>/dev/null || true

    echo "VPC '$name' deleted (bridge='$br')"
}
# create namespace && attach to vpc bridge
create_ns() {
    local vpc$1; local namespace=$2 local ipcidr=$3
    local dev="veth-$namespace" local peer="dev-br"
    local br="vpc-$vpc-br"
    # create ns
    run ip netns add "$namespace" || true
    # create v-eth
    run ip link add "$dev" type veth peer name "peer"
    # set v-eth to ns
    run ip link set "$dev" netns "$namespace" || true
    # set peer to bridge
    run ip link set "peer" master "$br" || true
    run ip link set "peer" up || true
    run ip link set "$dev" up || true
    # set ns ip ( add ip to ns)
    run ip netns exec "$namespace" ip addr add "$ipcidr" dev "$dev" || true
    # set ip up
    run ip netns exec "$namespace" ip link set "$dev" up || true
    # set local up
    run ip netns exec "$namespace" ip link set lo up || true
    # set default up for fall back
    run ip netns exec "$namespace" ip route add default via "$gateway_cidr" || true

    
    echo "Namespace '$namespace' created"

}

delete_ns() {
    local name=$1
    run ip netns delete "$name" || true
    echo "Namespace '$name' deleted"