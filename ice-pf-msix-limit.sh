#!/bin/bash
# ice-pf-msix-limit.sh
#
# Limits the PF's MSI-X vector reservation and active channel
# count on Intel E810 (ice driver) NICs so that the remaining
# vectors are available for SR-IOV VFs.
#
# Triggered by udev when an ice PF interface appears, runs
# before sriov-config.service and NetworkManager.service.
#
# Configuration: /etc/ice-pf-msix-limit.conf

CONF="/etc/ice-pf-msix-limit.conf"

# Defaults
ICE_PF_COMBINED_CHANNELS=16
ICE_TARGET_PCI_ADDRESSES=""

log() { echo "ice-pf-msix-limit: $*"; logger -t ice-pf-msix-limit "$*" 2>/dev/null || true; }

# Load config
if [ -f "$CONF" ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | tr -d '[:space:]')
        value=$(echo "$value" | tr -d '[:space:]')
        case "$key" in
            ICE_PF_COMBINED_CHANNELS)  ICE_PF_COMBINED_CHANNELS="$value" ;;
            ICE_TARGET_PCI_ADDRESSES)  ICE_TARGET_PCI_ADDRESSES="$value" ;;
        esac
    done < "$CONF"
else
    log "WARN: $CONF not found, using defaults."
fi

DESIRED_PF_MSIX=$(( ICE_PF_COMBINED_CHANNELS + 1 ))

log "Config: channels=$ICE_PF_COMBINED_CHANNELS msix_vec_per_pf_max=$DESIRED_PF_MSIX targets=${ICE_TARGET_PCI_ADDRESSES:-all}"

# Collect PCI addresses that need a devlink reload.
# Each PF (PCI function) requires its own reload.
devices_to_reload=""

for net_dir in /sys/class/net/*/device; do
    [ -e "$net_dir/driver" ] || continue
    driver=$(basename "$(readlink "$net_dir/driver")")
    [ "$driver" = "ice" ] || continue

    [ -e "$net_dir/sriov_totalvfs" ] || continue
    total_vfs=$(cat "$net_dir/sriov_totalvfs")
    [ "$total_vfs" -gt 0 ] 2>/dev/null || continue

    pci_addr=$(basename "$(readlink "$net_dir")")
    iface=$(basename "$(dirname "$net_dir")")

    # Filter by PCI address if configured
    if [ -n "$ICE_TARGET_PCI_ADDRESSES" ]; then
        if ! echo ",$ICE_TARGET_PCI_ADDRESSES," | grep -q ",$pci_addr,"; then
            continue
        fi
    fi

    log "Processing PF $iface ($pci_addr)"

    # Check current devlink value
    current_pf_max=$(devlink dev param show "pci/$pci_addr" name msix_vec_per_pf_max 2>/dev/null \
        | grep -oP 'value\s+\K\d+' | head -1 || true)

    if [ -z "$current_pf_max" ]; then
        log "  WARN: devlink msix_vec_per_pf_max not available. Skipping."
        continue
    fi

    if [ "$current_pf_max" -eq "$DESIRED_PF_MSIX" ]; then
        log "  devlink msix_vec_per_pf_max already $DESIRED_PF_MSIX."
    else
        log "  Setting devlink msix_vec_per_pf_max: $current_pf_max -> $DESIRED_PF_MSIX"
        if devlink dev param set "pci/$pci_addr" \
                name msix_vec_per_pf_max value "$DESIRED_PF_MSIX" cmode driverinit; then
            devices_to_reload="$devices_to_reload $pci_addr"
        else
            log "  ERROR: devlink param set failed."
        fi
    fi

    # Set ethtool combined channels only when no devlink reload is
    # pending. Reloaded PFs get ethtool applied after the reload loop.
    if ! echo "$devices_to_reload" | grep -q "$pci_addr"; then
        current_channels=$(ethtool -l "$iface" 2>/dev/null \
            | awk '/^Current/{f=1} f && /Combined:/{print $2; exit}' || true)
        if [ -n "$current_channels" ] && [ "$current_channels" -ne "$ICE_PF_COMBINED_CHANNELS" ]; then
            log "  Setting $iface combined channels: $current_channels -> $ICE_PF_COMBINED_CHANNELS"
            ethtool -L "$iface" combined "$ICE_PF_COMBINED_CHANNELS" || \
                log "  ERROR: ethtool -L failed."
        else
            log "  $iface combined channels already ${current_channels:-unknown}."
        fi
    else
        log "  Deferring ethtool -L until after devlink reload."
    fi

done

# Reload each PF that had its driverinit param changed.
# After reload, PF interfaces are re-created and udev fires
# again. RemainAfterExit=yes prevents the service from re-running.
for pci_addr in $devices_to_reload; do
    log "Reloading device pci/$pci_addr to apply driverinit params"
    if devlink dev reload "pci/$pci_addr"; then
        log "  Reload successful. PF interfaces will be re-created."
    else
        log "  ERROR: devlink dev reload failed for pci/$pci_addr."
    fi
done

# After reload, set ethtool combined channels on re-created PFs.
for pci_addr in $devices_to_reload; do
    iface=$(basename /sys/bus/pci/devices/"$pci_addr"/net/* 2>/dev/null)
    if [ -z "$iface" ] || [ "$iface" = "*" ]; then
        log "WARN: No interface found for $pci_addr after reload. Skipping ethtool."
        continue
    fi
    current_channels=$(ethtool -l "$iface" 2>/dev/null \
        | awk '/^Current/{f=1} f && /Combined:/{print $2; exit}' || true)
    if [ -n "$current_channels" ] && [ "$current_channels" -ne "$ICE_PF_COMBINED_CHANNELS" ]; then
        log "Setting $iface combined channels: $current_channels -> $ICE_PF_COMBINED_CHANNELS"
        ethtool -L "$iface" combined "$ICE_PF_COMBINED_CHANNELS" || \
            log "ERROR: ethtool -L failed for $iface after reload."
    else
        log "$iface combined channels already ${current_channels:-unknown}."
    fi
done
