#!/bin/bash

##
## Final head-node stage: deploy the bridge-instrumented DSB-SN services on the
## cluster with blueprint-docc-mod/utils/build_deploy_dsb.sh, seed the social
## graph, and prove the result works (pods Running, load accepted, traces in
## Jaeger).  Runs after setup-bridges.sh.  A failed check fails the stage, so a
## "ready" experiment means the application is really up.
##
## Parameters can be overridden by hand, e.g. to try another variant:
##   rm /local/setup/deploy-bridges-done
##   DEPLOYSPEC=docker_cgpb_es DEPLOYNAME=cgpb /local/repository/setup-deploy-bridges.sh
## Re-check a running deployment without rebuilding it:
##   DEPLOYVERIFYONLY=1 /local/repository/setup-deploy-bridges.sh
##

set -x

. "`dirname $0`/setup-lib.sh"

: ${DEPLOYVERIFYONLY:=0}
if [ -f $OURDIR/deploy-bridges-done ] && [ "$DEPLOYVERIFYONLY" != "1" ]; then
    echo "bridges deployment already done; not running again"
    exit 0
fi

logtstart "deploy-bridges"

: ${DEPLOYAPP:=1}
: ${DEPLOYSPEC:=docker_pb_es}
: ${DEPLOYNAME:=profile}
: ${DEPLOYCPD:=2}
: ${DEPLOYGC:=natural}
: ${DEPLOYSEED:=1}
: ${DEPLOYPINREQUESTS:=0}
: ${DEPLOYSMOKERPS:=100}
: ${DEPLOYSMOKESECS:=30}

SUMMARY=$OURDIR/bridges-deployment.txt

fail() {
    echo "ERROR: $*" | tee -a $SUMMARY
    logtend "deploy-bridges"
    exit 1
}

if [ "$DEPLOYAPP" != "1" ]; then
    echo "deployApp is off; leaving the cluster without an application"
    logtend "deploy-bridges"
    touch $OURDIR/deploy-bridges-done
    exit 0
fi

[ -f "$HOME/bridges-env.sh" ] || fail "no ~/bridges-env.sh; setup-bridges.sh did not finish"
. "$HOME/bridges-env.sh"
[ -f "$BLUEPRINT_DIR/.venv/bin/activate" ] || fail "no $BLUEPRINT_DIR/.venv"
. "$BLUEPRINT_DIR/.venv/bin/activate"

cat /dev/null > $SUMMARY

BP="$BLUEPRINT_DIR"
DSBSN="$BP/examples/dsb_sn"
LUA="$DSBSN/scripts/compose-post.lua"
# Wiring turns docker_<kind>_es into service names <base>-<kind>-es-ctr.
VARIANT=${DEPLOYSPEC#docker_}
VARIANT=${VARIANT//_/-}
WRKSVC=wrk2api-service-${VARIANT}-ctr
FOLDMARK="# Folded by setup-deploy-bridges.sh"

#
# Placement.  The fork's canonical layout pins to node-1..node-9.  When those
# are not all schedulable, fold it onto the nodes that are, and leave CPU
# requests out so the merged services do not over-reserve a node.
#
schedulable_nodes() {
    kubectl get nodes -o json | python3 -c '
import json, sys
for n in json.load(sys.stdin)["items"]:
    if not any(t.get("effect") == "NoSchedule" for t in n["spec"].get("taints") or []):
        print(n["metadata"]["name"])
' | sort -t- -k2 -n
}

prepare_placement() {
    NODEPIN="$DSBSN/node-pinning-${DEPLOYNAME}.yaml"
    PINFLAG=""
    [ "$DEPLOYPINREQUESTS" = "1" ] || PINFLAG="--no-pin-requests"

    # A hand-written pinning file wins; one we folded earlier is regenerated.
    if [ -f "$NODEPIN" ] && ! grep -qF "$FOLDMARK" "$NODEPIN"; then
	echo "using existing placement $NODEPIN"
	return 0
    fi
    rm -f "$NODEPIN"

    NODES=$(schedulable_nodes)
    [ -n "$NODES" ] || fail "kubectl reports no schedulable nodes"
    MISSING=0
    for i in 1 2 3 4 5 6 7 8 9; do
	echo "$NODES" | grep -qx "node-$i" || MISSING=1
    done
    if [ $MISSING -eq 0 ]; then
	echo "canonical node-1..node-9 placement fits this cluster"
	return 0
    fi

    echo "folding the canonical placement onto: $(echo $NODES)"
    PINFLAG="--no-pin-requests"
    TMPPIN=$(mktemp)
    python3 "$BP/utils/gen_node_pinning.py" "$VARIANT" "$TMPPIN" --no-requests \
	|| fail "gen_node_pinning.py failed"
    python3 - "$TMPPIN" "$NODEPIN" "$FOLDMARK" $NODES <<'PY' || fail "could not fold the node placement"
import sys, yaml
src, dst, mark, nodes = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
canonical = yaml.safe_load(open(src))
folded = {}
for i, (_, services) in enumerate(sorted(canonical.items(), key=lambda kv: int(kv[0].split('-')[1]))):
    folded.setdefault(nodes[i % len(nodes)], []).extend(services)
with open(dst, 'w') as f:
    f.write(mark + " from the canonical layout, for " + str(len(nodes)) + " schedulable nodes.\n")
    yaml.safe_dump(folded, f, default_flow_style=False, sort_keys=False)
PY
    rm -f "$TMPPIN"
}

#
# Build, push, apply, seed.
#
deploy() {
    prepare_placement

    # The application images build FROM the collector base image.
    BUILDCOLFLAG=""
    if ! curl -sf "http://$REGISTRY/v2/otelcontribcol/tags/list" | grep -q latest; then
	echo "otelcontribcol is not in the registry; building it now"
	BUILDCOLFLAG="--build-collector"
    fi
    SEEDFLAG="--noseed"
    [ "$DEPLOYSEED" = "1" ] && SEEDFLAG="--seed"

    DEPLOYLOG=$OURDIR/bridges-deploy-build.log
    "$BP/utils/build_deploy_dsb.sh" -s "$DEPLOYSPEC" -n "$DEPLOYNAME" \
	--cpd "$DEPLOYCPD" --gc "$DEPLOYGC" $PINFLAG $BUILDCOLFLAG --apply $SEEDFLAG \
	2>&1 | tee $DEPLOYLOG
    [ ${PIPESTATUS[0]} -eq 0 ] || fail "build_deploy_dsb.sh failed; see $DEPLOYLOG"
    grep -q "=== DONE" $DEPLOYLOG || fail "build_deploy_dsb.sh did not finish; see $DEPLOYLOG"
}

#
# Checks.  build_deploy_dsb.sh does not fail when pods never become Running, so
# everything is verified here against the live cluster.
#
variant_pods() {
    kubectl get pods --no-headers 2>/dev/null | grep -- "-${VARIANT}-ctr"
}

check_pods() {
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	TOTAL=$(variant_pods | wc -l)
	BAD=$(variant_pods | awk '{ split($2, r, "/"); if ($3 != "Running" || r[1] != r[2]) print }' | wc -l)
	[ "$TOTAL" -gt 0 ] && [ "$BAD" -eq 0 ] && break
	sleep 15
    done
    if [ "$TOTAL" -eq 0 ] || [ "$BAD" -ne 0 ]; then
	variant_pods | awk '$3 != "Running"'
	fail "pods not healthy: $BAD of $TOTAL for variant $VARIANT"
    fi
    RESTARTS=$(variant_pods | awk '{ s += $4 } END { print s + 0 }')
    echo "pods: $TOTAL Running and Ready, $RESTARTS restarts" | tee -a $SUMMARY
}

check_load() {
    NODEPORT=$(kubectl get svc "$WRKSVC" -o jsonpath='{.spec.ports[?(@.port==2000)].nodePort}')
    [ -n "$NODEPORT" ] || fail "no NodePort on $WRKSVC"
    URL="http://10.10.1.1:$NODEPORT"
    if [ "$DEPLOYSEED" != "1" ]; then
	echo "load check skipped: social graph not seeded" | tee -a $SUMMARY
	return 0
    fi
    WRKLOG=$(mktemp)
    wrk -t2 -c10 -d${DEPLOYSMOKESECS}s -L -s "$LUA" "$URL" -R$DEPLOYSMOKERPS 2>&1 | tee $WRKLOG
    DONE=$(awk '/requests in/ { print $1 }' $WRKLOG)
    NON2XX=$(awk '/Non-2xx/ { print $NF }' $WRKLOG)
    NON2XX=${NON2XX:-0}
    RATE=$(awk '/Requests\/sec/ { print $2 }' $WRKLOG)
    rm -f $WRKLOG
    [ "${DONE:-0}" -gt 0 ] || fail "wrk completed no requests against $URL"
    # Tolerate the odd cold-start error, not a broken request path.
    [ $((NON2XX * 100)) -le "$DONE" ] || fail "$NON2XX of $DONE ComposePost requests were not 2xx"
    echo "load: $DONE ComposePost requests at $RATE req/s, $NON2XX non-2xx" | tee -a $SUMMARY
}

check_traces() {
    JAEGERIP=$(kubectl get pods -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    if p["metadata"]["name"].startswith("jaeger-"):
        print(p["status"]["podIP"]); break
')
    [ -n "$JAEGERIP" ] || fail "no Jaeger pod"
    [ "$DEPLOYSEED" = "1" ] || return 0
    TRACES=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
	RESULT=$(curl -sf "http://$JAEGERIP:16686/api/services" | python3 -c '
import json, sys, urllib.request
ip = sys.argv[1]
names = json.load(sys.stdin).get("data") or []
svc = next((n for n in names if "compose" in n.lower()), "")
count = spans = bridged = 0
if svc:
    url = "http://%s:16686/api/traces?service=%s&limit=20&lookback=1h" % (ip, svc)
    data = json.load(urllib.request.urlopen(url, timeout=30)).get("data") or []
    count = len(data)
    spans = max([len(t["spans"]) for t in data] or [0])
    # _br is the bridge payload the instrumentation attaches to a span.
    bridged = sum(any(g["key"] == "_br" for g in s["tags"]) for t in data for s in t["spans"])
print(svc, count, spans, bridged)
' "$JAEGERIP")
	set -- $RESULT
	if [ $# -eq 4 ] && [ "$2" -gt 0 ]; then
	    TRACESVC=$1; TRACES=$2; MAXSPANS=$3; BRIDGED=$4
	    break
	fi
	sleep 15
    done
    [ "$TRACES" -gt 0 ] || fail "no ComposePost traces reached Jaeger at $JAEGERIP"
    echo "traces: $TRACES fetched for $TRACESVC, largest has $MAXSPANS spans, $BRIDGED spans carry bridge data" | tee -a $SUMMARY
    # Only Path Bridge has been checked against this tag, so only it can fail here.
    if [ "$DEPLOYSPEC" = "docker_pb_es" ] && [ "$BRIDGED" -eq 0 ]; then
	fail "Path Bridge traces carry no _br bridge data"
    fi
}

if [ "$DEPLOYVERIFYONLY" != "1" ]; then
    deploy
fi
check_pods
check_load
check_traces

#
# Record where things are.  Replaced on every run so a new variant wins.
#
sed -i '/^# bridges deployment$/d; /^export BRIDGES_VARIANT=/d; /^export WRK2API_URL=/d' "$HOME/bridges-env.sh"
cat >> "$HOME/bridges-env.sh" <<EOF
# bridges deployment
export BRIDGES_VARIANT="$VARIANT"
export WRK2API_URL="$URL"
EOF

{
    echo "bridges deployment verified $(date '+%F %T')"
    echo "  spec         : $DEPLOYSPEC (cpd=$DEPLOYCPD gc=$DEPLOYGC)"
    echo "  variant      : $VARIANT"
    echo "  wrk2api      : $URL"
    echo "  jaeger       : http://$JAEGERIP:16686 (from node-0)"
} | tee -a $SUMMARY

logtend "deploy-bridges"
touch $OURDIR/deploy-bridges-done
exit 0
