#!/bin/bash
# test_connectivity.sh
# Test intra-VPC and inter-VPC connectivity before peering
set -euo pipefail

log() { echo "$1"; }

log "[Test] Intra-VPC subnet communication (ns1 <-> ns2)..."
ip netns exec ns1 curl -s --connect-timeout 2 http://192.168.1.20:8080 && log "ns1 can reach ns2 (PASS)" || log "ns1 cannot reach ns2 (FAIL)"
ip netns exec ns2 curl -s --connect-timeout 2 http://192.168.1.10:8080 && log "ns2 can reach ns1 (PASS)" || log "ns2 cannot reach ns1 (FAIL)"

log "[Test] Inter-VPC communication (ns1 <-> ns3, expect blocked)..."
ip netns exec ns1 curl -s --connect-timeout 2 http://192.168.2.10:8080 && log "ns1 can reach ns3 (FAIL)" || log "ns1 cannot reach ns3 (PASS)"
ip netns exec ns3 curl -s --connect-timeout 2 http://192.168.1.10:8080 && log "ns3 can reach ns1 (FAIL)" || log "ns3 cannot reach ns1 (PASS)"
