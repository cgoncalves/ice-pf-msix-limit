# ice-pf-msix-limit

Limit Intel E810 (ice driver) PF MSI-X vector reservation for SR-IOV.

## Problem Statement

The `ice` driver for Intel E810 series NICs uses a default algorithm that
scales PF MSI-X vector allocation with the host's CPU count. On nodes with
a high number of CPUs, this causes the driver to reserve an excessive number
of MSI-X interrupt vectors for the Physical Function (PF), leaving
insufficient vectors for Virtual Functions (VFs).

For example, on a node with 80 CPUs and an E810 NIC with 512 MSI-X vectors
per PF:

| Component | Vectors | Notes |
|---|---|---|
| PF reservation (`msix_vec_per_pf_max`) | 164 | Driver default: ~1 per CPU + overhead |
| PF active channels | 80 | One combined TX/RX queue pair per CPU |
| Remaining for VFs | 348 | 512 - 164 |
| Per-VF queues (16 VFs) | ~4 | 348 / 16 / ~5 vectors per VF |

Administrators targeting 16 RSS queues per VF cannot achieve this without
manually constraining the PF. The desired configuration requires two changes:

1. **`devlink msix_vec_per_pf_max`** — Cap the PF's MSI-X reservation at boot
   time (driverinit parameter, requires driver reload to take effect).
2. **`ethtool -L combined`** — Reduce the PF's active channel count
   (runtime, immediate).

With `msix_vec_per_pf_max=9` (8 channels + 1 admin vector), the remaining
503 vectors are available for VFs, easily supporting 16 queues per VF.

## PF MSI-X Budget Calculation

The administrator's input is a single value: the desired number of PF
combined channels (`ICE_PF_COMBINED_CHANNELS`). The devlink
`msix_vec_per_pf_max` is derived from it:

```
msix_vec_per_pf_max = ICE_PF_COMBINED_CHANNELS + 1
```

The `+ 1` accounts for the PF's admin queue, which requires its own MSI-X
vector regardless of the number of data channels.

The remaining vectors are implicitly available for VFs:

```
vectors_available_for_vfs = msix_table_size - msix_vec_per_pf_max
```

Where `msix_table_size` is the hardware MSI-X table capacity read from the
PCI config space (e.g., 512 for E810).

**Example** with `ICE_PF_COMBINED_CHANNELS=8` on an E810 with 512 vectors:

```
msix_vec_per_pf_max       =   8 + 1 =   9
vectors_available_for_vfs = 512 - 9 = 503
```

The ice driver distributes the remaining 503 vectors across VFs when they
are created. With 16 VFs, each VF receives ~31 vectors, more than enough
for 16 RSS queues per VF.

**Note:** The administrator does not need to specify the number of VFs or
desired queues per VF. The approach simply constrains the PF to the minimum
it needs and leaves everything else for VFs. The ice driver handles VF
vector distribution internally.

## How It Works

A udev rule detects ice PF interfaces as they appear and triggers a systemd
oneshot service that applies devlink and ethtool settings. On OpenShift, the
files are delivered as a MachineConfig.

1. Kernel loads the ice driver, PF network interfaces appear.
2. udev matches `ACTION=="add", SUBSYSTEM=="net", DRIVERS=="ice"` and
   starts `ice-pf-msix-limit.service` via `ENV{SYSTEMD_WANTS}`.
3. The service is ordered `Before=sriov-config.service` and
   `Before=NetworkManager.service`, ensuring it completes before any
   VFs are created.
4. The script iterates over all targeted ice PFs:
   - Sets `devlink msix_vec_per_pf_max` to the desired value if it
     differs from the current value. Tracks which physical devices
     (by PCI slot) need a reload.
   - Attempts `ethtool -L combined` on each PF. This change is
     effective only when no devlink reload follows — see below.
5. After the iteration, the script issues `devlink dev reload` once
   per physical device that had its driverinit parameter changed.
   The reload is synchronous — it blocks until the driver has
   reinitialized. This reinitializes all PFs on the physical device.
6. After reload, the driver creates PF interfaces with the new MSI-X
   budget. With `msix_vec_per_pf_max=9`, the driver can only allocate
   8 combined channels (9 vectors minus 1 admin queue), so the PF
   channel count is naturally capped without needing a separate
   ethtool call.
7. The udev rule fires again for the re-created interfaces, but the
   service has `RemainAfterExit=yes`, so systemd sees it as already
   active and does not re-run it.
8. `sriov-config.service` and NetworkManager start after the service
   completes, creating VFs with the full remaining MSI-X budget.

**Key design details:**

- `devlink driverinit` values do not persist across reboots. The script
  must set them and reload the device on every boot.
- `devlink dev reload` reinitializes the entire physical device (all
  PFs on the same slot), not just a single PF. The script deduplicates
  by physical slot to avoid redundant reloads.
- `RemainAfterExit=yes` prevents the service from re-running when the
  devlink reload re-creates PF interfaces and udev fires again. This
  is safe because the driver's channel count is naturally capped by
  the reduced vector budget after reload.

## Usage

### OpenShift

Generate and apply the MachineConfig:

```bash
./generate-machineconfig.sh > ice-pf-msix-limit-machineconfig.yaml
oc apply -f ice-pf-msix-limit-machineconfig.yaml
```

The MCO will drain and reboot worker nodes to apply the configuration.

To target a different machine config pool (default is `worker`):

```bash
./generate-machineconfig.sh -r worker-cnf > ice-pf-msix-limit-machineconfig.yaml
```

### Bare-Metal RHEL

Install the files manually:

```bash
cp ice-pf-msix-limit.conf /etc/
cp 99-ice-pf-msix-limit.rules /etc/udev/rules.d/
cp ice-pf-msix-limit.service /etc/systemd/system/
cp ice-pf-msix-limit.sh /usr/local/bin/
chmod +x /usr/local/bin/ice-pf-msix-limit.sh
reboot
```

### Configuration

Edit `/etc/ice-pf-msix-limit.conf` before applying (OpenShift) or
before rebooting (bare metal):

```bash
# Number of PF combined channels. devlink msix_vec_per_pf_max = this + 1.
ICE_PF_COMBINED_CHANNELS=8

# Limit to specific PCI addresses (empty = all ice SR-IOV PFs).
ICE_TARGET_PCI_ADDRESSES=
```

On OpenShift, override the config by creating a separate MachineConfig
that writes a custom `/etc/ice-pf-msix-limit.conf`.

### Verification

After the node reboots, verify the settings were applied:

```bash
# Check PF combined channels and devlink MSI-X reservation
for pf in $(ls -d /sys/class/net/*/device/driver 2>/dev/null | \
    while read d; do
        [ "$(basename $(readlink $d))" = "ice" ] && \
        basename $(dirname $(dirname $d))
    done); do
    pci=$(basename $(readlink /sys/class/net/$pf/device))
    echo "=== $pf ($pci) ==="
    echo "  combined channels: $(ethtool -l $pf 2>/dev/null | \
        awk '/^Current/{f=1} f && /Combined:/{print $2; exit}')"
    echo "  msix_vec_per_pf_max: $(devlink dev param show pci/$pci \
        name msix_vec_per_pf_max 2>/dev/null | \
        grep -oP 'value\s+\K\d+' | head -1)"
    echo "  msi_irqs (PF): $(ls /sys/bus/pci/devices/$pci/msi_irqs \
        2>/dev/null | wc -l)"
done
```

Check the service logs:

```bash
journalctl -u ice-pf-msix-limit.service
```
