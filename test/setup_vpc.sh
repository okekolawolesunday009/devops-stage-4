#!/bin/bash
# setup_vpc.sh
# Set up VPCs and namespaces for all tests
set -euo pipefail

bash vpcctl.sh create_vpc -v vpc1 -c 192.168.1.0/24
bash vpcctl.sh create_vpc -v vpc2 -c 192.168.2.0/24
bash vpcctl.sh create_ns -v vpc1 -n ns1 -c 192.168.1.10/24 -g 192.168.1.1/24 -b vpc-vpc1-br -t public -a true -i etho
bash vpcctl.sh create_ns -v vpc1 -n ns2 -c 192.168.1.20/24 -g 192.168.1.1/24 -b vpc-vpc1-br -t private -a false -i etho
bash vpcctl.sh create_ns -v vpc2 -n ns3 -c 192.168.2.10/24 -g 192.168.2.1/24 -b vpc-vpc2-br -t public -a true -i etho
