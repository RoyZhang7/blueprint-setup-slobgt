# blueprint-setup-slobgt

CloudLab profile for the Blueprint **bridges** / SLO-budget-sampling work.

It is the stock Utah [k8s-profile](https://gitlab.flux.utah.edu/johnsond/k8s-profile)
(Kubespray cluster, local registry, NFS storage class, dashboard) with two extra
head-node stages. `setup-bridges.sh` clones and builds everything the DSB-SN
bridge experiments need. `setup-deploy-bridges.sh` then deploys and seeds the
bridge-instrumented Social Network and checks that it works.

**The end state of a "ready" experiment is a running testbed:** the bridged
DSB-SN services on the cluster, with a seeded social graph, the priority
collector on every node, and Jaeger on Elasticsearch receiving traces. An
optional non-Kubernetes mode gives a single docker-ce node with the same repos
and toolchain, without the deployment.

## What you get on node-0

| Path (under the repository directory, default `$HOME`) | Content |
| --- | --- |
| `blueprint-docc-mod/` | Blueprint fork, branch `retctx-reject-impl`: bridge SDK, DSB-SN wiring specs, `d2k8s/`, `utils/build_deploy_dsb.sh` and friends. `.venv/` has pyyaml + aiohttp. |
| `opentelemetry-collector-contrib/` | Collector fork, branch `retctx-reject-impl` (priorityprocessor, configdiscoveryreceiver). The `otelcontribcol` image is built and pushed to the in-cluster registry `10.10.1.1:30000` when `buildCollector` is on. |
| `bridges/` | Reconstruction, simulators and analysis; all `cmd/*` built into `bridges/bin/`. `.venv/` with `requirements-local.txt` when `bridgesPython` is on. |
| `DeathStarBench/` | docc-lab fork; `wrk2` is built and installed as `/usr/local/bin/wrk`; `socialNetwork/datasets` feeds the seeder. |
| `~/bridges-env.sh` | PATH for Go / `$GOPATH/bin`, Go caches on `/storage`, repo locations, registry; sourced from `.bashrc` and `.profile`. |

Toolchain: Go (`goVersion`, default 1.26.4) in `/usr/local/go`, `protoc` +
`protoc-gen-go` + `protoc-gen-go-grpc`, `goimports`, kompose (`komposeVersion`,
default v1.38.0), build-essential, luarocks/luasocket, jq.

The fork's `utils/*.sh` helpers hardcode `/users/tomislav/...`; the profile
rewrites those to the chosen repository directory (list of touched files in
`/local/setup/bridges-path-rewrite.log`). `vm.max_map_count=262144` is set on
every node for Elasticsearch.

## Parameters

Bridges-specific (the rest are the unchanged k8s-profile parameters):

| Parameter | Default | Meaning |
| --- | --- | --- |
| `installKubernetes` | on | Kubespray cluster. Off = plain docker-ce + compose plugin, single node, compose-only Blueprint work. |
| `repoDir` | `` (= `$HOME`) | Where the four repos are cloned. Use e.g. `/storage/<user>` to keep them off NFS. |
| `blueprintRepo` / `blueprintBranch` | docc-lab/blueprint-docc-mod @ `retctx-reject-impl` | Blueprint fork. |
| `collectorRepo` / `collectorBranch` | docc-lab/opentelemetry-collector-contrib @ `retctx-reject-impl` | Collector fork. |
| `bridgesRepo` / `bridgesBranch` | docc-lab/bridges @ `main` | Bridges repo. |
| `dsbRepo` / `dsbBranch` | docc-lab/DeathStarBench @ default | DeathStarBench. |
| `goVersion` | 1.26.4 | Must be >= 1.25.2 (bridges go.mod). |
| `komposeVersion` | v1.38.0 | kompose release tag. |
| `buildCollector` | on | Build the collector image during setup (and push it with Kubernetes). ~10-15 min. |
| `bridgesPython` | on | `bridges/.venv` with numpy/pandas/scipy/matplotlib/seaborn. |
| `installOrTools` / `orToolsVersion` | off | Prebuilt OR-Tools + `bridges/bin/trace_recon_cgprb` (cpsat build tag). |
| `cpuPinGhz` | 0 | Pin every node's CPU clock via `utils/pin-cpu-22ghz.sh` (2.2 = paper setting). Not reboot-persistent. |
| `deployApp` | on | Build, deploy, seed and verify DSB-SN at the end of setup. A failed check fails the setup. About 15 min. |
| `deploySpec` | `docker_pb_es` | Variant: `docker_pb_es`, `docker_cgpb_es`, `docker_sb_es`, `docker_rc_es` or `docker_v_es`. |
| `deployName` | `profile` | Names `examples/dsb_sn/build_<name>/` and `node-pinning-<name>.yaml`. |
| `deployCpd` / `deployGc` | 2 / `natural` | Checkpoint distance and application GC mode. |
| `deploySeed` | on | Seed the social graph. The load and trace checks are skipped when off. |
| `deployPinRequests` | off | Keep the canonical CPU requests (needs roughly 40-core nodes and node-1..node-9). |

Keep `containerManager=docker`, `doLocalRegistry=on` and `doNFS=on` (defaults):
the build scripts use the docker CLI, the local-registry option is what marks
`10.10.1.0/24` as an insecure registry on all nodes, and the in-cluster
registry's PVC uses the `nfs-client` storage class.

## After setup

`/local/setup/bridges-deployment.txt` records the variant, the wrk2api URL and
the check results. New logins get `WRK2API_URL` from `~/bridges-env.sh`.

```sh
# drive load against the running application
wrk -t2 -c10 -d30s -L -s ~/blueprint-docc-mod/examples/dsb_sn/scripts/compose-post.lua $WRK2API_URL -R100

# re-run the health checks without rebuilding
DEPLOYVERIFYONLY=1 /local/repository/setup-deploy-bridges.sh

# replace it with another variant (the live one is evicted)
source ~/blueprint-docc-mod/.venv/bin/activate
cd ~/blueprint-docc-mod
utils/build_deploy_dsb.sh -s docker_cgpb_es -n cgpb --cpd 2 --gc natural --no-pin-requests --apply --seed
```

`utils/build_deploy_dsb.sh -h` lists the knobs; `utils/User_Guide.md` and
`utils/k8s-configuration.md` in the fork describe the experiment workflow.

The deploy stage fails the setup unless all of these hold:

- Every pod of the variant is Running and Ready.
- A short wrk2 ComposePost run completes, with at most 1% non-2xx responses.
- ComposePost traces can be fetched back from Jaeger. For `docker_pb_es`, their spans must also carry the `_br` bridge tag.

**Cluster size.** The fork's canonical placement pins services to `node-1` ...
`node-9` (`node-0` is the tainted control plane), which is why `nodeCount`
defaults to 10. When those nodes are not all schedulable, the deploy stage folds
the layout onto the nodes that are and leaves CPU requests out. The placement
then differs from the paper setup, so use 10 nodes for measurements. A
hand-written `examples/dsb_sn/node-pinning-<name>.yaml` always wins.

CPU requests are off by default because the canonical values assume 40-core
nodes. When redeploying by hand, note that `--skip-build` regenerates the
manifests with a new image tag without building those images, so pods fail with
`ImagePullBackOff`; re-run without it.

Logs: `/local/logs/setup.log` (driver), `/local/logs/setup-bridges.sh.log`,
`/local/logs/setup-deploy-bridges.sh.log`, `/local/setup/bridges-deploy-build.log`,
`/local/setup/bridges-summary.txt`, `/local/setup/bridges-warnings.log`
(non-fatal problems such as a failed optional build). Setup timing is in
`/local/setup/setup-time.log`.

Re-running a stage by hand (as your user, on node-0):

```sh
rm /local/setup/bridges-done
BUILDCOLLECTOR=0 /local/repository/setup-bridges.sh
```

Every profile parameter can be overridden in the environment the same way
(`REPODIR`, `BLUEPRINTBRANCH`, `GOVERSION`, ...).

## Layout

```
profile.py              geni-lib profile (k8s-profile parameters + bridges parameters)
setup-driver.sh         runs the per-node script lists; branches on installKubernetes
setup-lib.sh            k8s-profile library (parameters, node maps, helpers)
setup-ssh.sh            all nodes: ssh keys between nodes
setup-disk-space.sh     all nodes: LVM on spare disks -> /storage, docker/kubelet dirs
setup-sysctl.sh         all nodes: vm.max_map_count etc.
setup-docker.sh         all nodes (no-k8s mode only): docker-ce + compose plugin
setup-nfs-*.sh, setup-nginx.sh, setup-ssl.sh, setup-kubespray.sh,
setup-kubernetes-extra.sh, setup-end.sh, manifest-to-*.py, getmanifests.py
                        unchanged from k8s-profile
setup-bridges.sh        node-0: repos, toolchain, builds, registry, env file
setup-deploy-bridges.sh node-0: deploy, seed and verify the bridged DSB-SN
```
