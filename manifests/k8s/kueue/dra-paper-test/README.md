# DRA Quota Cascade Experiment — Reproducibility Set

Verified end-to-end on **2026-06-09** against:
* Kueue **v0.17.3** ([release](https://github.com/kubernetes-sigs/kueue/releases/tag/v0.17.3))
* Host kubeadm Kubernetes **v1.36.1**
* NVIDIA DRA driver (DeviceClass `gpu.nvidia.com` with `extendedResourceName: nvidia.com/gpu`)
* NVIDIA GeForce GT 1030 single-GPU node

This artifact set corresponds to paper §V-E "DRA-Backed GPU Admission on a Live Cluster". The captured experimental output lives at `docs/experiments/2026-06-09-dra-quota-cascade-output.md`.

## Files

| # | File | What it does |
|---|------|--------------|
| 00 | `00-original-kueue-manager-config-backup.yaml` | **Restore point** — the `kueue-manager-config` ConfigMap as it was BEFORE the experiment. Apply this to roll back. |
| 00 | `00-kueue-configuration-patch.yaml` | New `kueue-manager-config` with `resources.deviceClassMappings` added. |
| 01 | `01-namespace-and-queue.yaml` | Namespace `dra-paper-test` + ResourceFlavor + ClusterQueue (covers cpu/memory/`dra.gpu.nvidia.com`) + LocalQueue. |
| 02 | `02-resourceclaimtemplate.yaml` | `resource.k8s.io/v1` `ResourceClaimTemplate` requesting one device from the `gpu.nvidia.com` DeviceClass. |
| 03 | `03-jobs.yaml` | Two Jobs each referencing the template via `spec.resourceClaims`. |

## Apply order

> **Step 0 — back up YOUR existing Kueue Configuration BEFORE applying anything below.**
> The committed `00-original-kueue-manager-config-backup.yaml` is the **author's** pre-experiment state on 2026-06-09 and may differ from yours. Step 1 will overwrite your existing `kueue-manager-config` ConfigMap. Capture yours first:
>
> ```bash
> kubectl get cm -n kueue-system kueue-manager-config -o yaml > my-kueue-manager-config-backup.yaml
> ```
>
> Keep `my-kueue-manager-config-backup.yaml` safe; the "Rollback" section below restores to the author's snapshot, **not** to yours.

```bash
export KUBECONFIG=/tmp/kubeconfig-host

# 1. Configure Kueue with deviceClassMappings (applies + restart needed)
kubectl apply -f 00-kueue-configuration-patch.yaml

# 2. Patch controller-manager deployment to enable BOTH feature gates.
#    NOTE: gates MUST be on CLI args, not in ConfigMap — Kueue refuses
#    to start if both places specify them ("feature gates for CLI and
#    configuration cannot both specified").
kubectl patch deployment kueue-controller-manager -n kueue-system \
  --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args",
       "value":["--config=/controller_manager_config.yaml",
                "--zap-log-level=2",
                "--feature-gates=DRAExtendedResources=true,DynamicResourceAllocation=true"]}]'

# 3. Force restart so the ConfigMap is reloaded
kubectl rollout restart deployment/kueue-controller-manager -n kueue-system
kubectl rollout status deployment/kueue-controller-manager -n kueue-system --timeout=120s

# 4. Apply namespace + queues + RCT + Jobs
kubectl apply -f 01-namespace-and-queue.yaml
kubectl apply -f 02-resourceclaimtemplate.yaml
kubectl apply -f 03-jobs.yaml

# 5. Observe
sleep 10 && kubectl get workloads,jobs -n dra-paper-test
kubectl get clusterqueue dra-paper-cq -o jsonpath='{.status.flavorsUsage}{"\npending="}{.status.pendingWorkloads}{"  admitted="}{.status.admittedWorkloads}'; echo
```

## Rollback

```bash
kubectl apply -f 00-original-kueue-manager-config-backup.yaml
kubectl patch deployment kueue-controller-manager -n kueue-system --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--config=/controller_manager_config.yaml","--zap-log-level=2","--feature-gates=DRAExtendedResources=true"]}]'
kubectl rollout restart deployment/kueue-controller-manager -n kueue-system
kubectl delete -f 03-jobs.yaml -f 02-resourceclaimtemplate.yaml -f 01-namespace-and-queue.yaml --ignore-not-found
```

## Expected outcome (verified 2026-06-09)

| Time | State |
|------|-------|
| t=0  | Submit 2 Jobs |
| t=~5s | Both Suspended, `pending=2 admitted=0` |
| t=~10s | One admitted (`admitted=1, flavorsUsage[dra.gpu.nvidia.com]=1`), other Suspended |
| t=40s | First Job `Complete 1/1` (30s sleep + ~10s overhead) |
| t=~45s | Cascade: second Job admitted, ResourceClaim auto-created (`state=allocated, reserved`) |
| t=75s | Second Job `Complete 1/1` |

Full log + JSON snapshots at `docs/experiments/2026-06-09-dra-quota-cascade-output.md`.

## What went wrong before we got this right (operator notes)

Three failed attempts before the third configuration loaded successfully:

1. **First attempt** — put `deviceClassMappings` at top level. Pod crashed with `strict decoding error: unknown field "deviceClassMappings"`. The field must be nested under `resources:`.
2. **Second attempt** — put `featureGates:` block in the ConfigMap AND kept `--feature-gates=...` on controller CLI. Pod crashed with `featureGates: Invalid value: ... feature gates for CLI and configuration cannot both specified`. Pick one location.
3. **Third attempt** (successful) — `deviceClassMappings` nested under `resources:`; feature gates ONLY on CLI args (NOT in ConfigMap).

A fourth bug surfaced after start: Workloads stayed `pending=2` because the ClusterQueue only covered `dra.gpu.nvidia.com` and Pods also requested cpu/memory. Error: `couldn't assign flavors to pod set main: resource cpu unavailable in ClusterQueue`. Fix: add `cpu` and `memory` to `coveredResources` (already in `01-namespace-and-queue.yaml`).

## Honest caveats

- Cascade gap ("~5 seconds") was inferred from job log timestamps: job-1 done at 18:04:45 UTC, job-2 starting at 18:04:50 UTC. The 5-second gap is wall-time between job-1 Pod completion and job-2 container start, which includes (a) Job controller marking job-1 Complete, (b) Kueue Workload reconciliation, (c) Workload quota release, (d) second Workload Admitted transition, (e) DRA driver creating ResourceClaim from template, (f) Pod scheduling and Pull-If-Necessary, (g) container start. No individual step was measured.
- "Both Workloads Admitted=True" in the final snapshot reflects the END-STATE — both reached Admitted=True at different times in sequence (job-1 first, job-2 after job-1 completed). Quota was never exceeded.
- Job-1's ResourceClaim was garbage-collected on Job completion (DRA ResourceClaim ownerRef = Pod, Pod completion releases). Only job-2's RC was visible in the t=~45s snapshot because job-1 had just released.
- The cluster was upgraded from K8s v1.35.x (used for §V-D experiments) to v1.36.1 between the two experiment sessions. Paper §V-D records the older cluster; this directory records the current one.
