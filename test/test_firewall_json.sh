#!/bin/bash
# test_firewall_json.sh
# Test applying/removing firewall (security group) rules from a JSON policy
set -euo pipefail

log() { echo "$1"; }

# Example security group policy
cat > security_groups.json <<EOF
[
  {
    "subnet": "192.168.1.0/24",
    "ingress": [
      {"port": 8080, "protocol": "tcp", "action": "allow"},
      {"port": 22, "protocol": "tcp", "action": "deny"}
    ]
  }
]
EOF

log "[Firewall Test] Applying security group to ns1 (allow 8080, deny 22)"
bash vpcctl.sh add_sg -v vpc1 -n ns1 -c 192.168.1.0/24 -p security_groups.json -a true

log "[Firewall Test] Testing allowed port (8080)..."
ip netns exec ns1 python3 -m http.server 8080 &
sleep 1
curl -s --connect-timeout 2 http://192.168.1.10:8080 && log "Port 8080 allowed (PASS)" || log "Port 8080 blocked (FAIL)"

log "[Firewall Test] Testing denied port (22)..."
ip netns exec ns1 nc -l -p 22 &
sleep 1
nc -zv 192.168.1.10 22 && log "Port 22 allowed (FAIL)" || log "Port 22 blocked (PASS)"

log "[Firewall Test] Removing security group from ns1..."
bash vpcctl.sh remove_sg -v vpc1 -n ns1 -c 192.168.1.0/24 -p security_groups.json -a false
