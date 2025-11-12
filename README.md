# Virtual Private Cloud (VPC) Management

This project includes a minimal VPC manager for Linux, implemented in `vpcctl.sh`. It uses Linux bridges, network namespaces, veth pairs, and iptables to simulate VPC-like networking locally.

## Features

- Create and delete VPCs (Linux bridges)
- Create and delete network namespaces (subnets)
- Attach namespaces (subnets) to VPCs using veth pairs
- Assign gateway IPs to VPCs
- Peer and unpeer VPCs
- Public/private subnets (with NAT for public)
- List and clean up VPCs and namespaces

## Environment Variables

Most commands support environment variables as input. If set, env vars take precedence over positional arguments. Useful for scripting and CI.

**Supported variables:**
- `VPC1`, `VPC2` — VPC names
- `NS1`, `NS2` — Namespace names
- `CIDR1`, `CIDR2` — CIDR blocks for VPCs or subnets
- `GW1`, `GW2` — Gateway addresses
- `BR1`, `BR2` — Bridge names
- `SUBNET_TYPE`, `NAT_ENABLED` — Subnet type and NAT flag

**Example `.env`:**
```sh
VPC1="vpc1"
VPC2="vpc2"
CIDR1="192.168.1.0/24"
CIDR2="192.168.2.0/24"
NS1="ns1"
NS2="ns2"
GW1="192.168.1.1/24"
GW2="192.168.2.1/24"
BR1="vpc-vpc1-br"
BR2="vpc-vpc2-br"
SUBNET_TYPE="public"
NAT_ENABLED="true"
```

**Usage:**
```sh
set -a
[ -f .env ] && . .env
set +a
./vpcctl.sh create_vpc   # uses $VPC1 and $CIDR1 if set
./vpcctl.sh create_ns    # uses env vars for all params if set
./vpcctl.sh peer_vpcs    # uses $VPC1 $VPC2 $CIDR1 $CIDR2 if set
```

## Usage

Run the script with the desired command:

```sh
./vpcctl.sh <command>
```

### Commands

- `create_vpc <vpc_name> <cidr_block>`  
  Create a new VPC (bridge) with the specified name and CIDR block. Supports env vars.

- `delete_vpc <vpc_name>`  
  Delete the specified VPC.

- `create_ns <vpc_name> <namespace> <ipcidr> <gateway_cidr> <bridge> <public|private> <nat_enabled>`  
  Create a namespace (subnet), attach it to the VPC bridge, assign an IP, set default route, and specify if public (NAT enabled) or private (internal-only). Supports env vars.

- `delete_ns <namespace>`  
  Delete the specified namespace.

- `peer_ns <ns1> <ns2> <bridge> <cidr1> <cidr2>`  
  Peer two network namespaces (subnets) via a bridge, restricting traffic to the given CIDRs. Supports env vars.

- `peer_vpcs -v <vpc1> -w <vpc2> -c <cidr1> -d <cidr2> -g <gw1> -h <gw2>`  
  Peer two VPCs (bridges) with a veth pair, restricting traffic to the given CIDRs. Gateways are required. Supports env vars.
- `unpeer_vpcs -v <vpc1> -w <vpc2> -c <cidr1> -d <cidr2> -g <gw1> -h <gw2>`  
  Unpeer two VPCs and remove all routes and rules. Gateways are required. Supports env vars.

- `cleanup_all`  
  Remove all VPCs and namespaces, flush iptables.

- `help`  
  Show usage instructions.

---

### Modular Test Scripts

- `test/setup_vpc.sh`: Set up VPCs and namespaces
- `test/test_connectivity.sh`: Test intra/inter-VPC connectivity before peering
- `test/test_peering.sh`: Test VPC peering with CIDR restrictions
- `test/test_firewall_json.sh`: Test applying/removing firewall JSON policies
- `test/cleanup_vpc.sh`: Cleanup resources

---

### Firewall JSON Policy Example

```sh
# Example: Apply security group rules to ns1
bash vpcctl.sh add_sg vpc1 ns1 192.168.1.0/24 security_groups.json

# Remove rules
bash vpcctl.sh remove_sg vpc1 ns1 192.168.1.0/24 security_groups.json
```

See `test/test_firewall_json.sh` for a full test scenario.

## Example

```sh
# Create a VPC named 'dev' with gateway 10.0.0.1/24
./vpcctl.sh create_vpc -v vpc1 -c 192.168.1.0/24

# Create a public subnet 'pub1' in VPC 'dev' (NAT enabled)
./vpcctl.sh create_ns -v vpc1 -n ns1 -c 192.168.1.10/24 -g 192.168.1.1/24 -b vpc-vpc1-br -t public -a true -i etho

# Create a private subnet 'priv1' in VPC 'dev' (internal-only)
./vpcctl.sh create_ns -v vpc1 -n ns2 -c 192.168.1.20/24 -g 192.168.1.1/24 -b vpc-vpc1-br -t private -a false -i etho

# Peer two VPCs, allowing only specific CIDRs to communicate
./vpcctl.sh peer_vpcs -v vpc1 -w vpc2 -c 192.168.1.0/24 -d 192.168.2.0/24 -g 192.168.1.1/24 -h 192.168.2.1/24

# Unpeer two VPCs
./vpcctl.sh unpeer_vpcs -v vpc1 -w vpc2 -c 192.168.1.0/24 -d 192.168.2.0/24 -g 192.168.1.1/24 -h 192.168.2.1/24

# Cleanup all
./vpcctl.sh cleanup_all
```

## Security Groups (Firewall Rules)

You can define subnet-level firewall rules (simulating security groups) using a JSON policy file and apply them to namespaces.

### Example policy: `security_groups.json`
```json
[
  {
    "subnet": "10.0.0.0/24",
    "ingress": [
      {"port": 80, "protocol": "tcp", "action": "allow"},
      {"port": 22, "protocol": "tcp", "action": "deny"}
    ]
  }
]
```

### Applying/removing rules to a namespace

To apply security group rules:
```sh
./vpcctl.sh add_sg <vpc_name> <namespace> <subnet_cidr> security_groups.json
```

To remove security group rules:
```sh
./vpcctl.sh remove_sg <vpc_name> <namespace> <subnet_cidr> security_groups.json
```

## Deploying Web Servers for Connectivity Testing

You can use either a Python HTTP server or Nginx in your namespaces to test connectivity and isolation.

### Python HTTP server
```sh
ip netns exec <namespace1> python3 -m http.server 8081 &

ip netns exec <namespace2> curl http://<target_ip1>:8081
```

### Nginx
Install Nginx if not already present:
```sh
sudo apt-get install nginx -y
```
Start Nginx in a namespace:
```sh
ip netns exec <namespace2> nginx
```
Test from another namespace or the host:
```sh
ip netns exec <namespace1> curl http://<target_ip2>
```

This applies or removes the ingress rules for the subnet to the namespace using iptables. For example, port 80 will be allowed and port 22 denied if present in the rules.
