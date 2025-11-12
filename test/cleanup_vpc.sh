#!/bin/bash
# cleanup_vpc.sh
# Cleanup all VPCs and namespaces after tests
set -euo pipefail

bash vpcctl.sh cleanup_all
