#!/bin/bash

##
## Head-node (node-0) setup of the Blueprint "bridges" stack:
##
##   $REPODIR/blueprint-docc-mod               Blueprint fork (DSB-SN wiring, d2k8s, utils/)
##   $REPODIR/opentelemetry-collector-contrib  collector fork (priorityprocessor)
##   $REPODIR/bridges                          offline reconstruction / analysis
##   $REPODIR/DeathStarBench                   wrk2 + social-graph seeder data
##
## plus the toolchain they need (Go, protoc + Go plugins, goimports, kompose,
## wrk, python venvs).  Runs as the experiment creator from setup-driver.sh
## after Kubernetes is up (or after setup-docker.sh when Kubernetes is off).
##
## Every profile parameter is defaulted below, so this script can also be run
## by hand on a node (optionally overriding parameters in the environment),
## e.g.  BUILDCOLLECTOR=0 /local/repository/setup-bridges.sh
##
## Idempotent: steps that already happened are skipped; the whole script is
## skipped once $OURDIR/bridges-done exists (remove it to re-run).
##

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs (OURDIR, SUDO, SWAPPER, STORAGEDIR, maybe_install_packages,
# logtstart/logtend, and the profile parameters from $OURDIR/parameters).
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/bridges-done ]; then
    echo "bridges already set up; not running again"
    exit 0
fi

logtstart "bridges"

#
# Profile parameters (uppercased by manifest-to-parameters.py; booleans are
# 1/0), with defaults for manual runs.
#
: ${INSTALLKUBERNETES:=1}
: ${REPODIR:=}
: ${BLUEPRINTREPO:=https://github.com/docc-lab/blueprint-docc-mod.git}
: ${BLUEPRINTBRANCH:=retctx-reject-impl}
: ${COLLECTORREPO:=https://github.com/docc-lab/opentelemetry-collector-contrib.git}
: ${COLLECTORBRANCH:=retctx-reject-impl}
: ${BRIDGESREPO:=https://github.com/docc-lab/bridges.git}
: ${BRIDGESBRANCH:=main}
: ${DSBREPO:=https://github.com/docc-lab/DeathStarBench.git}
: ${DSBBRANCH:=}
: ${GOVERSION:=1.26.4}
: ${KOMPOSEVERSION:=v1.38.0}
: ${BUILDCOLLECTOR:=1}
: ${BRIDGESPYTHON:=1}
: ${INSTALLORTOOLS:=0}
: ${ORTOOLSVERSION:=v9.15/or-tools_amd64_ubuntu-22.04_cpp_v9.15.6755.tar.gz}
: ${CPUPINGHZ:=0}
# In-cluster registry (blueprint-docc-mod/utils/registry-service.yaml, NodePort
# 30000 on the head node's management IP); this is what build_deploy_dsb.sh
# pushes to and what the kubelets pull from.
: ${REGISTRY:=10.10.1.1:30000}

[ -z "$REPODIR" ] && REPODIR="$HOME"

BP="$REPODIR/blueprint-docc-mod"
COLLECTOR="$REPODIR/opentelemetry-collector-contrib"
BRIDGES="$REPODIR/bridges"
DSB="$REPODIR/DeathStarBench"
ENVFILE="$HOME/bridges-env.sh"
WARNLOG="$OURDIR/bridges-warnings.log"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}
warn() {
    echo "WARN: $*" >&2
    echo "$(date '+%F %T') $*" >> $WARNLOG
}

case `uname -m` in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) fail "unsupported arch `uname -m`" ;;
esac

#
# 1. Distro packages: build tools (wrk2, cgo), protobuf, lua for wrk2 scripts,
#    python venv, misc CLI tools the utils scripts shell out to.
#
$SUDO apt-get update
maybe_install_packages git curl ca-certificates rsync unzip make \
    build-essential g++ pkg-config libssl-dev libz-dev luarocks \
    protobuf-compiler libprotobuf-dev python3 python3-venv python3-pip \
    jq zstd bc
protoc --version || fail "protoc not installed"

#
# 2. Go toolchain, pinned to $GOVERSION, in /usr/local/go.  The module and
#    build caches go on the local extra disk ($STORAGEDIR) when it exists,
#    because home directories are NFS and the collector build is large.
#
GOROOT=/usr/local/go
GOPATH="$HOME/go"
CURRENT_GO=""
[ -x $GOROOT/bin/go ] && CURRENT_GO=`$GOROOT/bin/go version | awk '{print $3}'`
if [ "$CURRENT_GO" = "go${GOVERSION}" ]; then
    echo "Go go${GOVERSION} already installed"
else
    TARBALL="go${GOVERSION}.linux-${ARCH}.tar.gz"
    curl -fsSL -o /tmp/$TARBALL "https://go.dev/dl/$TARBALL" \
	|| fail "could not download Go $GOVERSION ($TARBALL)"
    $SUDO rm -rf $GOROOT
    $SUDO tar -C /usr/local -xzf /tmp/$TARBALL || fail "could not unpack Go"
    rm -f /tmp/$TARBALL
fi
GOCACHEBASE=""
if mountpoint -q "${STORAGEDIR:-/storage}" 2>/dev/null; then
    GOCACHEBASE="${STORAGEDIR:-/storage}/$SWAPPER"
    $SUDO mkdir -p $GOCACHEBASE
    $SUDO chown $SWAPPER $GOCACHEBASE
    export GOCACHE="$GOCACHEBASE/go-build"
    export GOMODCACHE="$GOCACHEBASE/go-mod"
fi
export GOPATH
export PATH="$PATH:$GOROOT/bin:$GOPATH/bin"
go version || fail "go not runnable"

#
# 3. Go tools: protoc plugins (Blueprint codegen), goimports (used by
#    build_deploy_dsb.sh to strip dead imports from generated code).
#
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest \
    || fail "protoc-gen-go install failed"
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest \
    || fail "protoc-gen-go-grpc install failed"
go install golang.org/x/tools/cmd/goimports@latest \
    || fail "goimports install failed"

#
# 4. kompose (docker-compose -> k8s, used by blueprint-docc-mod/d2k8s).
#
if [ -x /usr/local/bin/kompose ] && /usr/local/bin/kompose version 2>/dev/null | grep -q "${KOMPOSEVERSION#v}"; then
    echo "kompose $KOMPOSEVERSION already installed"
else
    curl -fsSL -o /tmp/kompose \
	"https://github.com/kubernetes/kompose/releases/download/${KOMPOSEVERSION}/kompose-linux-${ARCH}" \
	|| fail "could not download kompose $KOMPOSEVERSION"
    chmod +x /tmp/kompose
    $SUDO mv /tmp/kompose /usr/local/bin/kompose
fi
kompose version

#
# 5. Clone the repositories side by side under $REPODIR (the fork's scripts
#    locate the collector and DeathStarBench relative to blueprint-docc-mod).
#    Existing clones are left untouched.
#
clone_repo() {
    # clone_repo <url> <dest> <branch-or-empty> [extra git clone args]
    url="$1"; dest="$2"; ref="$3"; shift 3
    if [ -d "$dest/.git" ]; then
	echo "already cloned: $dest"
	return 0
    fi
    if [ -n "$ref" ]; then
	# Branch or tag: cheap single-branch clone.  A bare commit falls
	# through to a full clone + checkout.
	git clone --branch "$ref" "$@" "$url" "$dest" && return 0
	rm -rf "$dest"
	git clone "$@" "$url" "$dest" || return 1
	(cd "$dest" && git checkout "$ref") || return 1
	return 0
    fi
    git clone "$@" "$url" "$dest"
}
mkdir -p "$REPODIR" || fail "cannot create $REPODIR"
clone_repo "$BLUEPRINTREPO" "$BP" "$BLUEPRINTBRANCH" \
    || fail "clone of $BLUEPRINTREPO ($BLUEPRINTBRANCH) failed"
clone_repo "$COLLECTORREPO" "$COLLECTOR" "$COLLECTORBRANCH" \
    || fail "clone of $COLLECTORREPO ($COLLECTORBRANCH) failed"
clone_repo "$BRIDGESREPO" "$BRIDGES" "$BRIDGESBRANCH" \
    || fail "clone of $BRIDGESREPO ($BRIDGESBRANCH) failed"
clone_repo "$DSBREPO" "$DSB" "$DSBBRANCH" --recurse-submodules \
    || fail "clone of $DSBREPO failed"
(cd "$DSB" && git submodule update --init --recursive) \
    || warn "DeathStarBench submodule update failed"

#
# 6. The fork hardcodes Tomislav's home directory for the repo locations:
#    utils/ helpers (REPO, COLLECTOR_SRC, SEED_DIR, ...) and the wiring specs
#    (examples/*/wiring/specs/docker.go points at the collector fork's
#    test-config-bridges.yaml).  Rewrite them to $REPODIR, the same way
#    bridges/scripts/metal_setup.sh does.  Archived per-run material
#    (utils/analysis, examples/*/ramp_analysis, build_*, _manifest_snapshots,
#    docs) is left alone.
#
REWRITELOG=$OURDIR/bridges-path-rewrite.log
if [ "$REPODIR" != "/users/tomislav" ]; then
    FILES=`{
	grep -l '/users/tomislav' "$BP"/utils/*.sh "$BP"/utils/*.py 2>/dev/null
	grep -rl '/users/tomislav' --include='*.go' --include='*.py' --include='*.sh' --exclude-dir='build_*' \
	    "$BP"/examples/*/wiring "$BP"/runtime/plugins "$BP"/d2k8s 2>/dev/null
    } | sort -u`
    if [ -n "$FILES" ]; then
	echo "$(date '+%F %T') rewriting /users/tomislav -> $REPODIR in:" >> $REWRITELOG
	for f in $FILES; do
	    echo "  $f" >> $REWRITELOG
	    sed -i "s#/users/tomislav#$REPODIR#g" "$f" || fail "sed failed on $f"
	done
    fi
fi

#
# 7. wrk2 load generator from DeathStarBench -> /usr/local/bin/wrk
#    (needs luasocket for the DSB lua scripts).
#
if [ -x /usr/local/bin/wrk ]; then
    echo "wrk already installed"
elif [ -d "$DSB/wrk2" ]; then
    $SUDO luarocks install luasocket || warn "luarocks install luasocket failed"
    if make -C "$DSB/wrk2"; then
	$SUDO cp "$DSB/wrk2/wrk" /usr/local/bin/wrk && $SUDO chmod +x /usr/local/bin/wrk
    else
	warn "wrk2 build failed; /usr/local/bin/wrk not installed"
    fi
else
    warn "$DSB/wrk2 missing; wrk not built"
fi

#
# 8. Python venv for Blueprint's d2k8s (pyyaml) and the DSB-SN seeder (aiohttp).
#
if [ ! -x "$BP/.venv/bin/pip" ]; then
    python3 -m venv "$BP/.venv" || fail "venv creation failed in $BP"
fi
"$BP/.venv/bin/pip" install -q --upgrade pip
if [ -f "$BP/d2k8s/requirements.txt" ]; then
    "$BP/.venv/bin/pip" install -q -r "$BP/d2k8s/requirements.txt" || fail "d2k8s requirements failed"
else
    "$BP/.venv/bin/pip" install -q 'pyyaml>=6.0.1' || fail "pyyaml install failed"
fi
"$BP/.venv/bin/pip" install -q aiohttp || fail "aiohttp install failed"

#
# 9. bridges: build every command (no OR-Tools needed; cpsat is behind a
#    build tag), optional analysis venv, optional OR-Tools + cpsat binaries.
#
(cd "$BRIDGES" && go build -o bin/ ./cmd/...) \
    || warn "bridges 'go build ./cmd/...' failed"
if [ "$BRIDGESPYTHON" = "1" ]; then
    if [ ! -x "$BRIDGES/.venv/bin/pip" ]; then
	python3 -m venv "$BRIDGES/.venv" || warn "bridges venv creation failed"
    fi
    if [ -x "$BRIDGES/.venv/bin/pip" ]; then
	"$BRIDGES/.venv/bin/pip" install -q --upgrade pip
	REQ="$BRIDGES/requirements-local.txt"
	[ -f "$REQ" ] || REQ="$BRIDGES/requirements.txt"
	if [ -f "$REQ" ]; then
	    "$BRIDGES/.venv/bin/pip" install -q -r "$REQ" \
		|| "$BRIDGES/.venv/bin/pip" install -q numpy pandas scipy matplotlib seaborn \
		|| warn "bridges python requirements failed"
	else
	    "$BRIDGES/.venv/bin/pip" install -q numpy pandas scipy matplotlib seaborn \
		|| warn "bridges python requirements failed"
	fi
    fi
fi
ORTOOLSDIR=""
if [ "$INSTALLORTOOLS" = "1" ]; then
    ORTARBALL=`basename "$ORTOOLSVERSION"`
    if ! ls -d "$REPODIR"/or-tools_*_cpp_v* >/dev/null 2>&1; then
	curl -fsSL -o "/tmp/$ORTARBALL" \
	    "https://github.com/google/or-tools/releases/download/$ORTOOLSVERSION" \
	    && tar -C "$REPODIR" -xzf "/tmp/$ORTARBALL" \
	    || warn "OR-Tools download/unpack failed ($ORTOOLSVERSION)"
	rm -f "/tmp/$ORTARBALL"
    fi
    ORTOOLSDIR=`ls -d "$REPODIR"/or-tools_*_cpp_v* 2>/dev/null | head -1`
    if [ -n "$ORTOOLSDIR" -a -f "$ORTOOLSDIR/lib/libortools.so" ]; then
	# The cgo directives bake the OR-Tools install path; repoint them.
	for f in "$BRIDGES"/recon/cpsat_cgo.go "$BRIDGES"/recon/fullsat_cgo.go; do
	    [ -f "$f" ] && sed -i -e "s#/users/tomislav/or-tools_[^ /]*_cpp_v[0-9.]*#$ORTOOLSDIR#g" "$f"
	done
	(cd "$BRIDGES" && go build -tags cpsat -o bin/trace_recon_cgprb ./cmd/trace_recon) \
	    || warn "bridges cpsat build (trace_recon_cgprb) failed"
    else
	warn "OR-Tools not available; skipping cpsat build"
    fi
fi

#
# 10. Collector fork: build the otelcontribcol image (make docker-otelcontribcol
#     builds the linux binary through the ocb builder, then the image).  With
#     Kubernetes, first bring up the in-cluster registry from the fork's
#     manifests and push the image there so build_deploy_dsb.sh can deploy
#     without --build-collector.  docker group membership was granted by
#     setup-kubernetes-extra.sh / setup-docker.sh but is not in this process's
#     credentials yet, hence sg.
#
REGISTRY_OK=0
if [ "$INSTALLKUBERNETES" = "1" ]; then
    if kubectl cluster-info >/dev/null 2>&1; then
	kubectl create namespace registry --dry-run=client -o yaml | kubectl apply -f - \
	    && kubectl apply -f "$BP/utils/registry-pvc.yaml" \
			     -f "$BP/utils/registry-deployment.yaml" \
			     -f "$BP/utils/registry-service.yaml" \
	    || warn "applying the in-cluster registry manifests failed"
	if kubectl -n registry rollout status deploy/docker-registry --timeout=600s; then
	    REGISTRY_OK=1
	else
	    warn "in-cluster registry did not become ready (check PVC/storageclass nfs-client)"
	fi
    else
	warn "kubectl cannot reach the cluster; registry not applied"
    fi
fi
if [ "$BUILDCOLLECTOR" = "1" ]; then
    if [ "$INSTALLKUBERNETES" = "1" ]; then
	if [ $REGISTRY_OK -eq 1 ]; then
	    (cd "$COLLECTOR" && sg docker -c "bash ./build-and-push.sh $REGISTRY") \
		|| warn "collector build/push failed; rerun: cd $COLLECTOR && ./build-and-push.sh $REGISTRY"
	else
	    (cd "$COLLECTOR" && sg docker -c "make docker-otelcontribcol") \
		|| warn "collector image build failed"
	    warn "collector image built but not pushed (registry unavailable)"
	fi
    else
	(cd "$COLLECTOR" && sg docker -c "make docker-otelcontribcol") \
	    || warn "collector image build failed; rerun: cd $COLLECTOR && make docker-otelcontribcol"
    fi
fi

#
# 11. Optional CPU clock pin (bridges paper: 2.2 GHz on every node).
#
if [ "$CPUPINGHZ" != "0" -a -n "$CPUPINGHZ" -a -x "$BP/utils/pin-cpu-22ghz.sh" ]; then
    if [ "$INSTALLKUBERNETES" = "1" ] && kubectl cluster-info >/dev/null 2>&1; then
	bash "$BP/utils/pin-cpu-22ghz.sh" pin "$CPUPINGHZ" --all || warn "CPU pin --all reported errors"
    else
	bash "$BP/utils/pin-cpu-22ghz.sh" pin "$CPUPINGHZ" || warn "CPU pin reported errors"
    fi
fi

#
# 12. Environment file for interactive shells, sourced from ~/.bashrc and
#     ~/.profile.
#
cat > $ENVFILE <<EOF
# Generated by the bridges CloudLab profile (setup-bridges.sh) on $(date '+%F %T').
# source ~/bridges-env.sh
export BRIDGES_REPO_DIR="$REPODIR"
export BLUEPRINT_DIR="$BP"
export COLLECTOR_SRC="$COLLECTOR"
export BRIDGES_DIR="$BRIDGES"
export DSB_DIR="$DSB"
export REGISTRY="$REGISTRY"
export GOPATH="$GOPATH"
EOF
if [ -n "$GOCACHEBASE" ]; then
    cat >> $ENVFILE <<EOF
export GOCACHE="$GOCACHEBASE/go-build"
export GOMODCACHE="$GOCACHEBASE/go-mod"
EOF
fi
cat >> $ENVFILE <<'EOF'
case ":$PATH:" in
    *:/usr/local/go/bin:*) ;;
    *) export PATH="$PATH:/usr/local/go/bin:$GOPATH/bin" ;;
esac
EOF
[ -n "$ORTOOLSDIR" ] && echo "export ORTOOLS_DIR=\"$ORTOOLSDIR\"" >> $ENVFILE
PROTOCVER=$(protoc --version 2>/dev/null)
cat >> $ENVFILE <<EOF
# versions: go${GOVERSION} kompose ${KOMPOSEVERSION} ${PROTOCVER}
# repos: $BLUEPRINTREPO@$BLUEPRINTBRANCH ; $COLLECTORREPO@$COLLECTORBRANCH ; $BRIDGESREPO@$BRIDGESBRANCH ; $DSBREPO@${DSBBRANCH:-default}
EOF
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    touch "$rc"
    grep -qF 'bridges-env.sh' "$rc" \
	|| printf '\n# bridges CloudLab profile\n[ -f "$HOME/bridges-env.sh" ] && . "$HOME/bridges-env.sh"\n' >> "$rc"
done

#
# Summary.
#
SUMMARY=$OURDIR/bridges-summary.txt
GOVER=$(go version 2>/dev/null)
KOMPOSEVER=$(kompose version 2>/dev/null | head -1)
WRKBIN=$(command -v wrk || echo MISSING)
GOIMPORTSBIN=$(command -v goimports || echo MISSING)
NBIN=$(ls "$BRIDGES/bin" 2>/dev/null | wc -l)
COLIMG=$(sg docker -c 'docker images' 2>/dev/null | awk '/otelcontribcol/ { print $1 ":" $2 }' | xargs)
{
    echo "bridges setup finished $(date '+%F %T')"
    echo "  repodir      : $REPODIR"
    echo "  go           : $GOVER"
    echo "  protoc       : $PROTOCVER"
    echo "  kompose      : $KOMPOSEVER"
    echo "  wrk          : $WRKBIN"
    echo "  goimports    : $GOIMPORTSBIN"
    echo "  bridges bin  : $NBIN binaries"
    echo "  collector img: $COLIMG"
    echo "  registry     : $REGISTRY ready=$REGISTRY_OK"
    if [ -f $WARNLOG ]; then
	echo "  warnings     : see $WARNLOG"
	cat $WARNLOG
    fi
} | tee $SUMMARY

logtend "bridges"
touch $OURDIR/bridges-done
exit 0
