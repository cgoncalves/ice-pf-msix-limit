#!/bin/bash
# generate-machineconfig.sh
#
# Generates an OpenShift MachineConfig YAML that delivers the
# ice-pf-msix-limit udev rule, systemd service, script, and
# configuration file to worker nodes.
#
# Usage:
#   ./generate-machineconfig.sh
#   oc apply -f ice-pf-msix-limit-machineconfig.yaml
#
# Options:
#   -r ROLE   MachineConfig role label (default: worker)
#   -o FILE   Output file (default: ice-pf-msix-limit-machineconfig.yaml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLE="worker"
OUTFILE="ice-pf-msix-limit-machineconfig.yaml"

while getopts "r:o:" opt; do
    case "$opt" in
        r) ROLE="$OPTARG" ;;
        o) OUTFILE="$OPTARG" ;;
        *) echo "Usage: $0 [-r role] [-o outfile]" >&2; exit 1 ;;
    esac
done

encode() {
    base64 -w0 < "$1"
}

cat > "$OUTFILE" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-ice-pf-msix-limit
  labels:
    machineconfiguration.openshift.io/role: ${ROLE}
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/ice-pf-msix-limit.conf
          mode: 0644
          overwrite: true
          contents:
            source: data:text/plain;base64,$(encode "${SCRIPT_DIR}/ice-pf-msix-limit.conf")
        - path: /etc/udev/rules.d/99-ice-pf-msix-limit.rules
          mode: 0644
          overwrite: true
          contents:
            source: data:text/plain;base64,$(encode "${SCRIPT_DIR}/99-ice-pf-msix-limit.rules")
        - path: /etc/systemd/system/ice-pf-msix-limit.service
          mode: 0644
          overwrite: true
          contents:
            source: data:text/plain;base64,$(encode "${SCRIPT_DIR}/ice-pf-msix-limit.service")
        - path: /usr/local/bin/ice-pf-msix-limit.sh
          mode: 0755
          overwrite: true
          contents:
            source: data:text/plain;base64,$(encode "${SCRIPT_DIR}/ice-pf-msix-limit.sh")
EOF

echo "Generated $OUTFILE (role=$ROLE)"
