#!/bin/sh

##
## Kernel knobs needed by the DSB-SN stack on every node.  Elasticsearch
## (Jaeger's backing store in the *_es wiring specs) refuses to start with
## the stock vm.max_map_count=65530.
##

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/sysctl-done ]; then
    exit 0
fi

logtstart "sysctl"

cat <<EOS | $SUDO tee /etc/sysctl.d/90-bridges.conf
# installed by the bridges CloudLab profile (setup-sysctl.sh)
vm.max_map_count = 262144
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
EOS
$SUDO sysctl --system

logtend "sysctl"
touch $OURDIR/sysctl-done
exit 0
