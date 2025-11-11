#!/bin/bash
set euxo -pipefail
#
# --- CONFIG ---
BRIDGE=br0
SUBNET=10.10.0.0/24
GATEWAY=10.10.0.1
CON1=dev
CON2=prod
IF1=veth1
IF2=veth2
IF1_BR=veth1-br
IF2_BR=veth2-br
INTERNET_IF=eth0  # Change if your interface is different

# --- CLEANUP (if rerun) ---
sudo ip netns del $CON1 2>/dev/null || true
sudo ip netns del $CON2 2>/dev/null || true
sudo ip link set $BRIDGE down 2>/dev/null || true
sudo ip link del $BRIDGE 2>/dev/null || true

# --- STEP 1: Create namespaces ---
echo "[+] Creating network namespaces"
sudo ip netns add $CON1
sudo ip netns add $CON2

# --- STEP 2: Create veth pairs ---
echo "[+] Creating veth pairs"
sudo ip link add $IF1 type veth peer name $IF1_BR
sudo ip link add $IF2 type veth peer name $IF2_BR

# --- STEP 3: Move container ends into namespaces ---
echo "[+] Moving veth interfaces into namespaces"
sudo ip link set $IF1 netns $CON1
sudo ip link set $IF2 netns $CON2

# --- STEP 4: Create and configure bridge ---
echo "[+] Creating Linux bridge ($BRIDGE)"
sudo ip link add name $BRIDGE type bridge
sudo ip addr add $GATEWAY/24 dev $BRIDGE
sudo ip link set $BRIDGE up

# --- STEP 5: Attach host ends to bridge ---
echo "[+] Attaching veth host ends to bridge"
sudo ip link set $IF1_BR master $BRIDGE
sudo ip link set $IF2_BR master $BRIDGE
sudo ip link set $IF1_BR up
sudo ip link set $IF2_BR up

# --- STEP 6: Assign IPs inside containers ---
echo "[+] Assigning IPs to containers"
sudo ip netns exec $CON1 ip addr add 10.10.0.2/24 dev $IF1
sudo ip netns exec $CON2 ip addr add 10.10.0.3/24 dev $IF2
sudo ip netns exec $CON1 ip link set $IF1 up
sudo ip netns exec $CON2 ip link set $IF2 up
sudo ip netns exec $CON1 ip link set lo up
sudo ip netns exec $CON2 ip link set lo up

# --- STEP 7: Add default routes ---
echo "[+] Setting default routes"
sudo ip netns exec $CON1 ip route add default via $GATEWAY
sudo ip netns exec $CON2 ip route add default via $GATEWAY

# --- STEP 8: Test connectivity ---
echo "[+] Testing connectivity between containers"
sudo ip netns exec $CON1 ping -c 2 10.10.0.3 || echo "Ping failed (check setup)"

# --- STEP 9: Enable internet (NAT) ---
echo "[+] Enabling NAT for Internet access"
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s $SUBNET -o $INTERNET_IF -j MASQUERADE

# --- STEP 10: Optional port forwarding ---
echo "[+] Setting up port forwarding (host:8081 -> container1:8080)"
sudo iptables -t nat -A PREROUTING -p tcp --dport 8081 -j DNAT --to-destination 10.10.0.2:8080
sudo iptables -A FORWARD -p tcp -d 10.10.0.2 --dport 8080 -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT

echo "[+] Setup complete!"
echo "Test web server:"
echo "sudo ip netns exec $CON1 python3 -m http.server 8080 &"
echo "Then access it via: curl http://localhost:8081"

echo "[i] To clean up:"
echo "sudo ip netns del $CON1; sudo ip netns del $CON2; sudo ip link del $BRIDGE; sudo iptables -t nat -F"
