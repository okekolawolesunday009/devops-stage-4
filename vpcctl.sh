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

    # show existing 


    run ip link show "$br" >/dev/null 2>&1 || run ip link add name "$br" type bridge
    # create bridge
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
    local br="vpc-$vpc-br" local gateway_cidr=$4
    # create ns
    run ip netns add "$namespace" || true

    echo "Namespace '$namespace' created"
    # create v-eth
    run ip link add "$dev" type veth peer name "peer"
    # set v-eth to ns
    run ip link set "$dev" netns "$namespace" || true
    # set peer to bridge
    run ip link set "$peer" master "$br" || true
 
    run ip link set "$peer" up || true
 


    # set ns ip ( add ip to ns)
    run ip netns exec "$namespace" ip addr add "$ipcidr" dev "$dev" || true
    # set ip up
    run ip netns exec "$namespace" ip link set "$dev" up || true
    # set local up
    run ip netns exec "$namespace" ip link set lo up || true
    # set default up for fall back
    run ip netns exec "$namespace" ip route add default via "$gateway_cidr" || true


    run ip netns exec "$namespace" ip route add default via  "$gateway_cidr" dev "$dev" || true
  

    
    

}

delete_ns() {
    local namespace=$1
    run ip netns delete "$namespace" 2>/dev/null || true

    for p in $(ip -o link show | awk -F ': ' '{print $2}' | grep -E  "veth-$namespace-br| veth-$namespace\$" || true); do
        run ip link delete "$p" 2>/dev/null || true
    done
    echo "Namespace '$namespace' deleted"
}

peer_vpcs(){
    local vpc1=$1
    local vpc2=$2
    local br1="vpc-$vpc1-br"
    local br2="vpc-$vpc2-br"
   

    if [ "$vpc1 == $vpc2"]; then
        echo "vpc cannot peer with itself"
        return 1
    fi
    
    run ip link add name "$vpc1" type veth peer name "$vpc2"
    run ip link set "$vpc1" master "$br1"
    run ip link set "$vpc2" master "$br2"
    run ip link set "$vpc1" up
    run ip link set "$vpc2" up
    
    echo "VPC '$vpc1' and '$vpc2' are peered"
    echo "Peered $vpc1 <-> $vpc2 ($br1 <-> $br2)"
    echo "Add SG rules to control inter-VPC traffic (add-sg/del-sg)"
    
}