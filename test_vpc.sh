#!/bin/bash
# test_vpc.sh
# Test script for validating VPC/subnet design and connectivity scenarios

set -euo pipefail
LOGFILE="vpc_test.log"
echo "--- VPC Test Run $(date) ---" > "$LOGFILE"

# Check for root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root." >&2
  exit 1
fi

# Check required commands
for cmd in bash ip iptables awk grep cut sysctl python3 curl; do
    command -v $cmd >/dev/null 2>&1 || { echo "$cmd is required but not installed. Aborting." >&2; exit 1; }
done

# Trap to clean up background jobs
cleanup_bg() {
    jobs -p | xargs -r kill 2>/dev/null || true
}
trap cleanup_bg EXIT

log() {
    echo "$1" | tee -a "$LOGFILE"
}

# 1. Create VPCs and subnets
log "[1] Creating VPCs and subnets..."
bash vpcctl.sh create_vpc vpc1 192.168.1.0/24
bash vpcctl.sh create_vpc vpc2 192.168.2.0/24

# Create namespaces (subnets): public and private in vpc1
bash vpcctl.sh create_ns vpc1 ns1 192.168.1.10/24 192.168.1.1/24 vpc-vpc1-br public true   # public subnet with NAT
bash vpcctl.sh create_ns vpc1 ns2 192.168.1.20/24 192.168.1.1/24 vpc-vpc1-br private false # private subnet, no NAT

# Create namespace in vpc2
bash vpcctl.sh create_ns vpc2 ns3 192.168.2.10/24 192.168.2.1/24 vpc-vpc2-br public true

# 2. Deploy simple web servers in each namespace
log "[2] Deploying web servers..."
ip netns exec ns1 python3 -m http.server 8080 &
ip netns exec ns2 python3 -m http.server 8080 &
ip netns exec ns3 python3 -m http.server 8080 &

# Wait for all web servers to be ready
for ns in ns1 ns2 ns3; do
    for i in {1..10}; do
        if ip netns exec $ns curl -s --connect-timeout 1 http://localhost:8080 >/dev/null; then
            log "$ns web server is up"
            break
        fi
        sleep 1
        if [ $i -eq 10 ]; then
            log "ERROR: $ns web server did not start in time"
            exit 1
        fi
    done
done

# 3. Test communication between subnets in same VPC
log "[3] Testing intra-VPC subnet communication (ns1 <-> ns2)..."
ip netns exec ns1 curl -s --connect-timeout 2 http://192.168.1.20:8080 && log "ns1 can reach ns2 (PASS)" || log "ns1 cannot reach ns2 (FAIL)"
ip netns exec ns2 curl -s --connect-timeout 2 http://192.168.1.10:8080 && log "ns2 can reach ns1 (PASS)" || log "ns2 cannot reach ns1 (FAIL)"

# 4. Test outbound access
log "[4] Testing outbound access..."
ip netns exec ns1 curl -s --connect-timeout 2 https://example.com && log "ns1 outbound access (PASS)" || log "ns1 outbound access (FAIL)"
ip netns exec ns2 curl -s --connect-timeout 2 https://example.com && log "ns2 outbound access (PASS/FAIL expected: should be blocked)"

# 5. Test inter-VPC communication (should fail)
log "[5] Testing inter-VPC communication (ns1 <-> ns3, expect blocked)..."
ip netns exec ns1 curl -s --connect-timeout 2 http://192.168.2.10:8080 && log "ns1 can reach ns3 (FAIL)" || log "ns1 cannot reach ns3 (PASS)"
ip netns exec ns3 curl -s --connect-timeout 2 http://192.168.1.10:8080 && log "ns3 can reach ns1 (FAIL)" || log "ns3 cannot reach ns1 (PASS)"

# 6. Peer namespaces and retest
log "[6] Peering namespaces (ns1 <-> ns3)..."
bash vpcctl.sh peer_ns ns1 ns3 vpc-vpc1-br
sleep 1
log "[6] Testing after namespace peering (should be allowed if routes are set)..."
ip netns exec ns1 curl -s --connect-timeout 2 http://192.168.2.10:8080 && log "ns1 can reach ns3 after ns peering (PASS)" || log "ns1 cannot reach ns3 after ns peering (FAIL)"
ip netns exec ns3 curl -s --connect-timeout 2 http://192.168.1.10:8080 && log "ns3 can reach ns1 after ns peering (PASS)" || log "ns3 cannot reach ns1 after ns peering (FAIL)"

# 7. Peer VPCs and retest
log "[7] Peering VPCs..."
bash vpcctl.sh peer_vpcs vpc1 vpc2
sleep 1
log "[7] Testing after VPC peering (should be allowed)..."
ip netns exec ns1 curl -s --connect-timeout 2 http://192.168.2.10:8080 && log "ns1 can reach ns3 after VPC peering (PASS)" || log "ns1 cannot reach ns3 after VPC peering (FAIL)"

# 7. Policy enforcement test (example: block ns2 -> ns1)
log "[7] Enforcing policy: block ns2 -> ns1..."
ip netns exec ns2 iptables -A OUTPUT -d 192.168.1.10 -j REJECT
ip netns exec ns2 curl -s --connect-timeout 2 http://192.168.1.10:8080 && log "ns2 can reach ns1 (FAIL: should be blocked)" || log "ns2 cannot reach ns1 (PASS: blocked as expected)"

# 8. Logging state
log "[8] Listing VPC state..."
vpcctl.sh list_state | tee -a "$LOGFILE"

# 9. Cleanup
log "[9] Cleaning up..."
vpcctl.sh cleanup_all
log "--- Test Complete ---"