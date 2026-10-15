#!/bin/bash
# Build + install dattobd from ~/dattobd via DKMS + tools/lib, load the module.
# Build as root: genconfig reads /boot/System.map (root-only on RHEL-likes) to
# resolve unexported symbols; as a user it silently gets 0 and modpost fails.
set -euo pipefail
V=${V:-0.12.2}
SRC=${SRC:-$HOME/dattobd}
cd "$SRC"
sudo make -j"$(nproc)" >/tmp/dattobd-build.log 2>&1 || { tail -20 /tmp/dattobd-build.log; exit 1; }
sudo dkms remove dattobd/$V --all >/dev/null 2>&1 || true
sudo rm -rf /usr/src/dattobd-$V && sudo mkdir -p /usr/src/dattobd-$V
sudo cp -r src/* /usr/src/dattobd-$V/
sudo make -C /usr/src/dattobd-$V -f Makefile clean >/dev/null 2>&1 || true
sed "s/@MODULE_VERSION@/$V/" dist/dattobd-dkms-conf | sudo tee /usr/src/dattobd-$V/dkms.conf >/dev/null
sudo dkms add dattobd/$V >/dev/null
sudo dkms install dattobd/$V 2>&1 | tail -1
sudo install -m755 app/dbdctl utils/update-img /usr/local/sbin/
sudo cp -a lib/libdattobd.so* /usr/local/lib/
echo /usr/local/lib | sudo tee /etc/ld.so.conf.d/local.conf >/dev/null; sudo ldconfig
echo dattobd | sudo tee /etc/modules-load.d/dattobd.conf >/dev/null
sudo modprobe dattobd
dkms status | grep dattobd
