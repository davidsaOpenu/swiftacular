#!/bin/sh
. $PCP_DIR/etc/pcp.env
. $PCP_SHARE_DIR/lib/pmdaproc.sh

iam=swiftdbinfo
domain=400
python_opt=true
daemon_opt=false

checkmodule -M -m -o allow-swiftdbinfo.mod allow-swiftdbinfo.te
semodule_package -o allow-swiftdbinfo.pp -m allow-swiftdbinfo.mod
sudo semodule -i allow-swiftdbinfo.pp

pmdaSetup
pmdaInstall
exit
