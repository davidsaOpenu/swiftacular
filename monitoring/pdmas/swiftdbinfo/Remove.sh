#! /bin/sh
. $PCP_DIR/etc/pcp.env
. $PCP_SHARE_DIR/lib/pmdaproc.sh

iam=swiftdbinfo

pmdaSetup
pmdaRemove
exit