# blueprint-setup-slobgt

CloudLab profile for the Blueprint **bridges** / SLO-budget-sampling work.

It is the stock Utah [k8s-profile](https://gitlab.flux.utah.edu/johnsond/k8s-profile)
(Kubespray cluster, local registry, NFS storage class, dashboard) with one extra
head-node stage, `setup-bridges.sh`, that clones and builds everything the
DSB-SN bridge experiments need, plus an optional non-Kubernetes mode that gives
a single docker-ce node with the same repos and toolchain.

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

Keep `containerManager=docker`, `doLocalRegistry=on` and `doNFS=on` (defaults):
the build scripts use the docker CLI, the local-registry option is what marks
`10.10.1.0/24` as an insecure registry on all nodes, and the in-cluster
registry's PVC uses the `nfs-client` storage class.

## After setup

```sh
source ~/bridges-env.sh                       # new logins do this automatically
source ~/blueprint-docc-mod/.venv/bin/activate
cd ~/blueprint-docc-mod
utils/build_deploy_dsb.sh -s docker_pb_es -n pb_test --cpd 2 --gc natural --apply --seed
```

`utils/build_deploy_dsb.sh -h` lists the variants (`docker_pb_es`,
`docker_cgpb_es`, `docker_sb_es`, `docker_v_es`, `docker_rc_es`) and knobs;
`utils/User_Guide.md` and `utils/k8s-configuration.md` in the fork describe the
experiment workflow.

**Cluster size.** When no `examples/dsb_sn/node-pinning-<name>.yaml` exists,
`build_deploy_dsb.sh` generates the paper's placement, which pins services to
`node-1` ... `node-9` (`node-0` is the tainted control plane). That is why
`nodeCount` defaults to 10. On a smaller cluster the pinned pods stay
`Pending` with "didn't match Pod's node affinity/selector"; write a pinning
file for the nodes you have before running with `--apply`, e.g. fold the
canonical layout onto three workers (service names are `<base>-<variant>-ctr`):

```yaml
# examples/dsb_sn/node-pinning-pb_test.yaml
node-1:
  - composepost-service-pb-es-ctr: {requests_cpu: 12000, limits_cpu: 12000}
  - hometimeline-cache-pb-es-ctr: {requests_cpu: 2000, limits_cpu: 2000}
  - hometimeline-service-pb-es-ctr: {requests_cpu: 5000, limits_cpu: 5000}
  - usertimeline-cache-pb-es-ctr: {requests_cpu: 2000, limits_cpu: 2000}
  - usertimeline-db-pb-es-ctr: {requests_cpu: 11000, limits_cpu: 11000}
  - usertimeline-service-pb-es-ctr: {requests_cpu: 8000, limits_cpu: 8000}
  - urlshorten-db-pb-es-ctr: {requests_cpu: 2000, limits_cpu: 2000}
  - urlshorten-service-pb-es-ctr: {requests_cpu: 5000, limits_cpu: 5000}
node-2:
  - social-cache-pb-es-ctr: {requests_cpu: 4000, limits_cpu: 4000}
  - social-db-pb-es-ctr: {requests_cpu: 25000, limits_cpu: 25000}
  - socialgraph-service-pb-es-ctr: {requests_cpu: 6000, limits_cpu: 6000}
  - media-service-pb-es-ctr: {requests_cpu: 2000, limits_cpu: 2000}
  - text-service-pb-es-ctr: {requests_cpu: 8000, limits_cpu: 8000}
  - userid-service-pb-es-ctr: {requests_cpu: 6000, limits_cpu: 6000}
  - user-service-pb-es-ctr: {requests_cpu: 3000, limits_cpu: 3000}
  - user-cache-pb-es-ctr: {requests_cpu: 2000, limits_cpu: 2000}
  - user-db-pb-es-ctr: {requests_cpu: 2000, limits_cpu: 2000}
node-3:
  - uniqueid-service-pb-es-ctr: {requests_cpu: 3000, limits_cpu: 3000}
  - usermention-service-pb-es-ctr: {requests_cpu: 4000, limits_cpu: 4000}
  - post-cache-pb-es-ctr: {requests_cpu: 2000, limits_cpu: 2000}
  - post-db-pb-es-ctr: {requests_cpu: 3000, limits_cpu: 3000}
  - post-storage-service-pb-es-ctr: {requests_cpu: 5000, limits_cpu: 5000}
  - jaeger-pb-es-ctr: {requests_cpu: 20000, limits_cpu: 20000}
  - elasticsearch-pb-es-ctr: {requests_cpu: 4000, limits_cpu: 4000}
```

and deploy with `--no-pin-requests` so the folded CPU requests do not
over-reserve the nodes. Note that `--skip-build` regenerates the manifests with
a new image tag without building those images (pods then fail with
`ImagePullBackOff`); re-run without it to redeploy.

Logs: `/local/logs/setup.log` (driver), `/local/logs/setup-bridges.sh.log`,
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
```
