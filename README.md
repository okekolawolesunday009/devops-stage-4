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

The VPC setup uses environment variables for configuration. Copy `.env-example` to `.env` and adjust values as needed:

| Variable            | Description                              | Example           |
|---------------------|------------------------------------------|-------------------|
| VPC_NAME            | Unique name for the virtual VPC           | vpc1              |
| CIDR_BLOCK          | Base IP range (VPC CIDR block)            | 10.0.0.0/16       |
| PUBLIC_SUBNET       | Subnet that allows NAT access             | 10.0.0.0/24       |
| PRIVATE_SUBNET      | Subnet without internet access            | 10.0.1.0/24       |
| INTERNET_INTERFACE  | Host’s outbound network interface         | eth0              |

Example `.env`:
```sh
VPC_NAME="vpc1"
CIDR_BLOCK="10.0.0.0/16"
PUBLIC_SUBNET="10.0.0.0/24"
PRIVATE_SUBNET="10.0.1.0/24"
INTERNET_INTERFACE="eth0"
```

To use these variables in your shell scripts, source the `.env` file at the top of your script:

```sh
set -a
[ -f .env ] && . .env
set +a
```

## Usage

Run the script with the desired command:

```sh
./vpcctl.sh <command>
```

### Commands

- `create_vpc <vpc_name> <gateway_cidr>`  
  Create a new VPC (bridge) with the specified name and gateway CIDR (e.g., 10.0.0.1/24).

- `delete_vpc <vpc_name>`  
  Delete the specified VPC.

- `create_ns <vpc_name> <namespace> <ipcidr> <gateway_cidr> <bridge> <public|private>`  
  Create a namespace (subnet), attach it to the VPC bridge, assign an IP, set default route, and specify if public (NAT enabled) or private (internal-only).

- `delete_ns <namespace>`  
  Delete the specified namespace.

- `peer_vpcs <vpc_name1> <vpc_name2>`  
  Peer two VPCs (connect bridges).

- `unpeer_vpcs <vpc_name1> <vpc_name2>`  
  Unpeer two VPCs.

- `list`  
  List all VPCs and namespaces (not implemented).

- `cleanup_all`  
  Remove all VPCs and namespaces, flush iptables.

- `help`  
  Show usage instructions.

## Example

```sh
# Create a VPC named 'dev' with gateway 10.0.0.1/24
./vpcctl.sh create_vpc dev 10.0.0.1/24

# Create a public subnet 'pub1' in VPC 'dev' (NAT enabled)
./vpcctl.sh create_ns dev pub1 10.0.0.2/24 10.0.0.1/24 vpc-dev-br public

# Create a private subnet 'priv1' in VPC 'dev' (internal-only)
./vpcctl.sh create_ns dev priv1 10.0.0.3/24 10.0.0.1/24 vpc-dev-br private

# Peer two VPCs, allowing only specific CIDRs to communicate
./vpcctl.sh peer_vpcs dev vpc2 10.0.0.0/24 10.1.0.0/24

# Unpeer two VPCs
./vpcctl.sh unpeer_vpcs dev vpc2

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

This applies or removes the ingress rules for the subnet to the namespace using iptables. For example, port 80 will be allowed and port 22 denied if present in the rules.
