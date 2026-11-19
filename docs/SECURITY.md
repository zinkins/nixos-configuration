# Host security maintenance

## SCTP module restriction

SCTP is not required by the configured services. The host blocks both
automatic alias-based loading and ordinary explicit modprobe requests for
the SCTP kernel module. This reduces local kernel attack surface; it is not
a substitute for kernel security updates.

After the configuration has been deployed, verify on the host:

```bash
uname -r
zcat /proc/config.gz | grep CONFIG_IP_SCTP
modprobe -n -v sctp
lsmod | grep '^sctp ' || true
```

For a modular kernel, expect CONFIG_IP_SCTP=m, an install command ending
in /bin/false (not insmod), and no loaded SCTP module. If SCTP is built
into the kernel, this mitigation does not disable it. If it was already
loaded, the configuration does not unload it automatically; a controlled
reboot is required to remove it from memory. Do not load the module to test
the mitigation.

Compare the booted and deployed kernels before deciding whether to reboot:

```bash
readlink -f /run/booted-system/kernel
readlink -f /run/current-system/kernel
```

A different kernel requires a reboot to take effect. A configuration-only
change does not require a reboot if the module is already absent and the
new modprobe policy is effective. Preserve the previous generation for
rollback. See [AUTO-UPDATE.md](AUTO-UPDATE.md) for deployment.
