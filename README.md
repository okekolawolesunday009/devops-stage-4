# Virtual Private Cloud (VPC) Management

This project includes a minimal VPC manager for Linux, implemented in `vpcctl.sh`. It uses Linux bridges, network namespaces, veth pairs, and iptables to simulate VPC-like networking locally.

## Features

- Create and delete VPCs (Linux bridges)
- Create and delete network namespaces
- Attach namespaces to VPCs using veth pairs
- Assign gateway IPs to VPCs
- Peer and unpeer namespaces with VPCs
- List and clean up VPCs

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
  Create a new VPC (bridge) with the specified name and gateway CIDR.

- `delete_vpc <vpc_name>`  
  Delete the specified VPC.

- `create-ns <vpc_name> <namespace> <ipcidr>`  
  Create a namespace, attach it to the VPC, and assign an IP.

- `delete-ns <namespace>`  
  Delete the specified namespace.

- `peer vpcs <vpc_name> <vpc2_name>`  
  Peer two VPCs.

- `unpeer vpcs <vpc_name> <vpc2_name>`  
  Unpeer two VPCs.

- `list`  
  List all VPCs.

- `cleanup-all`  
  Remove all VPCs and namespaces.

- `help`  
  Show usage instructions.

## Example

```sh
# Create a VPC named 'dev' with gateway 10.0.0.1/24
./vpcctl.sh create_vpc dev 10.0.0.1/24

# Create a namespace 'ns1' in VPC 'dev' with IP 10.0.0.2/24
./vpcctl.sh create-ns dev ns1 10.0.0.2/24

# List all VPCs
./vpcctl.sh list

# Delete namespace
./vpcctl.sh delete-ns ns1

# Delete VPC
./vpcctl.sh delete_vpc dev
```
