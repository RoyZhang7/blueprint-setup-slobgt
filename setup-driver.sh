#!/bin/bash

set -x

# Preserve legacy main logfile location
ln -s /local/logs/setup.log /local/setup/setup-driver.log

export SRC=`dirname $0`
cd $SRC
. $SRC/setup-lib.sh

# Profile parameter (uppercased by manifest-to-parameters.py; 1/0).
INSTALLKUBERNETES=${INSTALLKUBERNETES:-1}

if [ "$INSTALLKUBERNETES" = "1" ]; then
    # Stock k8s-profile pipeline, then the bridges stack and the deployed,
    # verified application on the head node.
    ALLNODESCRIPTS="setup-ssh.sh setup-disk-space.sh setup-sysctl.sh"
    HEADNODESCRIPTS="setup-nfs-server.sh setup-nginx.sh setup-ssl.sh setup-kubespray.sh setup-kubernetes-extra.sh setup-bridges.sh setup-deploy-bridges.sh setup-end.sh"
    WORKERNODESCRIPTS="setup-nfs-client.sh"
else
    # No Kubernetes: plain docker-ce host(s); repos + toolchain on the head node.
    ALLNODESCRIPTS="setup-ssh.sh setup-disk-space.sh setup-sysctl.sh setup-docker.sh"
    HEADNODESCRIPTS="setup-bridges.sh setup-end.sh"
    WORKERNODESCRIPTS=""
fi

# Don't run setup-driver.sh twice
if [ -f $OURDIR/setup-driver-done ]; then
    echo "setup-driver already ran; not running again"
    exit 0
fi
for script in $ALLNODESCRIPTS ; do
    cd $SRC
    $SRC/$script | tee - /local/logs/${script}.log 2>&1
    if [ ! $PIPESTATUS -eq 0 ]; then
	echo "ERROR: ${script} failed; aborting driver!"
	exit 1
    fi
done
if [ "$HOSTNAME" = "node-0" ]; then
    for script in $HEADNODESCRIPTS ; do
	cd $SRC
	$SRC/$script | tee - /local/logs/${script}.log 2>&1
	if [ ! $PIPESTATUS -eq 0 ]; then
	    echo "ERROR: ${script} failed; aborting driver!"
	    exit 1
	fi
    done
else
    for script in $WORKERNODESCRIPTS ; do
	cd $SRC
	$SRC/$script | tee - /local/logs/${script}.log 2>&1
	if [ ! $PIPESTATUS -eq 0 ]; then
	    echo "ERROR: ${script} failed; aborting driver!"
	    exit 1
	fi
    done
fi

exit 0
