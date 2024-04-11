#!/usr/bin/env bash
#  SPDX-License-Identifier: BSD-3-Clause
#  All rights reserved.

testdir=$(readlink -f $(dirname $0))
rootdir=$(readlink -f $testdir/../../..)
source $rootdir/test/common/autotest_common.sh
source $rootdir/test/nvmf/common.sh

rpc_py="$rootdir/scripts/rpc.py"
loops=5

SUBSYSNQN="nqn.2016-06.io.spdk:cnode1"
HOSTNQN="nqn.2016-06.io.spdk:host1"
HOSTID=$(uuidgen)

function connect() {
	nvme connect -t $TEST_TRANSPORT -n $SUBSYSNQN -q $HOSTNQN -I $HOSTID \
		-a "$NVMF_FIRST_TARGET_IP" -s "$NVMF_PORT" -i 4
	waitforserial "$NVMF_SERIAL" $1
	ctrl_id=$(nvme list-subsys -o json \
		| jq -r '.[].Subsystems[] | select(.NQN=='\"$SUBSYSNQN\"') | .Paths[0].Name')
	if [[ -z "$ctrl_id" ]]; then
		# The filter returned empty, so dump the raw JSON contents so we
		# can try to debug why - whether the connect actually failed
		# or we just aren't filtering the JSON correctly.
		# We ran into this with issue #3337, which is now resolved, but
		# leave this here just in case this pops up again in the future.
		nvme list-subsys -o json
	fi
}

function disconnect() {
	nvme disconnect -n $SUBSYSNQN
}

# $1 == hex nsid
function ns_is_visible() {
	nvme list-ns /dev/$ctrl_id | grep "$1"
	nguid=$(nvme id-ns /dev/$ctrl_id -n $1 -o json | jq -r ".nguid")
	[[ $nguid != "00000000000000000000000000000000" ]]
}

nvmftestinit
nvmfappstart -m 0xF

$rpc_py nvmf_create_transport $NVMF_TRANSPORT_OPTS -u 8192

MALLOC_BDEV_SIZE=64
MALLOC_BLOCK_SIZE=512

$rpc_py bdev_malloc_create $MALLOC_BDEV_SIZE $MALLOC_BLOCK_SIZE -b Malloc1
$rpc_py bdev_malloc_create $MALLOC_BDEV_SIZE $MALLOC_BLOCK_SIZE -b Malloc2

# No masking (all namespaces automatically visible)
$rpc_py nvmf_create_subsystem $SUBSYSNQN -a -s $NVMF_SERIAL
$rpc_py nvmf_subsystem_add_ns $SUBSYSNQN Malloc1 -n 1
$rpc_py nvmf_subsystem_add_listener $SUBSYSNQN -t $TEST_TRANSPORT -a $NVMF_FIRST_TARGET_IP -s $NVMF_PORT

# Namespace should be visible
connect
ns_is_visible "0x1"

# Add 2nd namespace and check visible
$rpc_py nvmf_subsystem_add_ns $SUBSYSNQN Malloc2 -n 2
ns_is_visible "0x1"
ns_is_visible "0x2"

disconnect

# Remove ns1 and re-add without auto visibility
# Note: we will leave ns2 with auto-attach for rest of this test
$rpc_py nvmf_subsystem_remove_ns $SUBSYSNQN 1
$rpc_py nvmf_subsystem_add_ns $SUBSYSNQN Malloc1 -n 1 --no-auto-visible

# ns1 should be invisible
connect 1
NOT ns_is_visible "0x1"
ns_is_visible "0x2"

# hot attach and check ns1 visible
$rpc_py nvmf_ns_add_host $SUBSYSNQN 1 $HOSTNQN
ns_is_visible "0x1"
ns_is_visible "0x2"

# hot detach and check ns1 invisible
$rpc_py nvmf_ns_remove_host $SUBSYSNQN 1 $HOSTNQN
NOT ns_is_visible "0x1"
ns_is_visible "0x2"

disconnect

# cold attach, connect and check ns1 visible
$rpc_py nvmf_ns_add_host $SUBSYSNQN 1 $HOSTNQN
connect 2
ns_is_visible "0x1"
ns_is_visible "0x2"

# detach and check ns1 invisible
$rpc_py nvmf_ns_remove_host $SUBSYSNQN 1 $HOSTNQN
NOT ns_is_visible "0x1"
ns_is_visible "0x2"

# hot detach ns2 should not work, since ns2 is auto-visible
NOT $rpc_py nvmf_ns_remove_host $SUBSYSNQN 2 $HOSTNQN
NOT ns_is_visible "0x1"
ns_is_visible "0x2"
disconnect

$rpc_py nvmf_delete_subsystem $SUBSYSNQN

trap - SIGINT SIGTERM EXIT

nvmftestfini
