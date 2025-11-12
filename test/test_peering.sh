#!/bin/bash
# test_peering.sh
# Test VPC peering with CIDR restrictions and negative test
set -euo pipefail

log() { echo "$1"; }

log "[Test] Peering VPCs with CIDR restrictions (192.168.1.0/24 <-> 192.168.2.0/24)..."
bash vpcctl.sh peer_vpcs vpc1 vpc2 192.168.1.0/24 192.168.2.0/24
sleep 1
log "[Test] After VPC peering (only allowed subnets should communicate)..."
ip netns exec ns1 curl -s --connect-timeout 2 http://192.168.2.10:8080 && log "ns1 can reach ns3 after VPC peering (PASS)" || log "ns1 cannot reach ns3 after VPC peering (FAIL)"
ip netns exec ns3 curl -s --connect-timeout 2 http://192.168.1.10:8080 && log "ns3 can reach ns1 after VPC peering (PASS)" || log "ns3 cannot reach ns1 after VPC peering (FAIL)"

log "[Test] Negative: ns2 (192.168.1.20) should NOT reach ns3 after peering..."
ip netns exec ns2 curl -s --connect-timeout 2 http://192.168.2.10:8080 && log "ns2 can reach ns3 (FAIL: should be blocked)" || log "ns2 cannot reach ns3 (PASS: blocked as expected)"
