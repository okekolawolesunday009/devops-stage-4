#!/bin/bash
# setup_vpc.sh
# Set up VPCs and namespaces for all tests
set -euo pipefail

bash vpcctl.sh create_vpc vpc1 192.168.1.0/24
bash vpcctl.sh create_vpc vpc2 192.168.2.0/24
bash vpcctl.sh create_ns vpc1 ns1 192.168.1.10/24 192.168.1.1/24 vpc-vpc1-br public true
bash vpcctl.sh create_ns vpc1 ns2 192.168.1.20/24 192.168.1.1/24 vpc-vpc1-br private false
bash vpcctl.sh create_ns vpc2 ns3 192.168.2.10/24 192.168.2.1/24 vpc-vpc2-br public true
