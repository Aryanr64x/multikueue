<#
.SYNOPSIS
  Rebuilds the MultiKueue + Kubeflow Trainer lab on kind:
  1 manager cluster + 2 worker clusters, one TrainJob dispatched to whichever worker has room.

.NOTES
  Versions that are known to work together (see Kueue issue #14722 for why Trainer 2.1 does NOT):
    Kubeflow Trainer 2.3.0  +  Kueue 0.19.3

  Expected repo layout - everything in the repo root, next to this script:
    .\setup.ps1
    .\worker-queue-setup.yaml
    .\worker-rbac.yaml
    .\manager-setup.yaml
    .\multikueue-trainjob.yaml
    .\kind-manager-kueue-config.yaml

  Usage:
    .\setup.ps1                 # full rebuild, then submit the demo TrainJob
    .\setup.ps1 -SkipTrainJob   # rebuild only
#>
param(
    [string]$ManifestDir    = $PSScriptRoot,
    [string]$ManagerConfig  = (Join-Path $PSScriptRoot "kind-manager-kueue-config.yaml"),
    [string]$TrainerVersion = "2.3.0",
    [string]$KueueVersion   = "v0.19.3",
    [string]$TorchImage     = "pytorch/pytorch:2.13.0-cuda13.0-cudnn9-runtime",
    [switch]$SkipImagePreload,
    [switch]$SkipTrainJob
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot   # run from anywhere; kubeconfigs and .gitignore land in the repo root
$Manager     = "manager"
$Workers     = @("worker-a", "worker-b")
$AllClusters = @($Manager) + $Workers
$Utf8NoBom   = New-Object System.Text.UTF8Encoding $false

function Step($msg)  { Write-Host "`n==== $msg ====" -ForegroundColor Cyan }
function Ok($msg)    { Write-Host "  OK  $msg" -ForegroundColor Green }
function Fail($msg)  { Write-Host "  FAIL $msg" -ForegroundColor Red; exit 1 }

# Native commands (kubectl, helm, kind) do not throw in PowerShell 5 - check exit codes explicitly.
function Run {
    param([string]$What, [scriptblock]$Cmd)
    & $Cmd
    if ($LASTEXITCODE -ne 0) { Fail "$What (exit code $LASTEXITCODE)" }
}

function Wait-Active {
    param([string]$Kind, [string]$Name, [int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $status = kubectl --context "kind-$Manager" get $Kind $Name `
            -o jsonpath="{.status.conditions[?(@.type=='Active')].status}" 2>$null
        if ($status -eq "True") { Ok "$Kind/$Name is Active"; return }
        Start-Sleep -Seconds 5
    }
    $msg = kubectl --context "kind-$Manager" get $Kind $Name `
        -o jsonpath="{.status.conditions[?(@.type=='Active')].message}" 2>$null
    Fail "$Kind/$Name not Active after ${TimeoutSec}s: $msg"
}

# ---------------------------------------------------------------------------
Step "0. Preflight"
foreach ($tool in @("kind", "kubectl", "helm", "docker")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "$tool not found on PATH" }
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { Fail "Docker is not running - start Docker Desktop first" }

$required = @(
    (Join-Path $ManifestDir "worker-queue-setup.yaml"),
    (Join-Path $ManifestDir "worker-rbac.yaml"),
    (Join-Path $ManifestDir "manager-setup.yaml"),
    $ManagerConfig
)
if (-not $SkipTrainJob) { $required += (Join-Path $ManifestDir "multikueue-trainjob.yaml") }
foreach ($f in $required) {
    if (-not (Test-Path $f)) { Fail "missing file: $f (all files must sit next to setup.ps1)" }
}
Ok "tools, Docker and repo files present"

# ---------------------------------------------------------------------------
Step "1. Create kind clusters (one at a time to avoid etcd timeouts)"
$existing = @(kind get clusters 2>$null)
foreach ($c in $AllClusters) {
    if ($existing -contains $c) { Ok "cluster $c already exists - reusing"; continue }
    Run "create cluster $c" { kind create cluster --name $c }
    Ok "cluster $c created"
}

# ---------------------------------------------------------------------------
if (-not $SkipImagePreload) {
    Step "2. Preload the PyTorch image (avoids a ~13 min pull per cluster)"
    Run "docker pull $TorchImage" { docker pull $TorchImage }
    foreach ($c in $AllClusters) {
        Run "kind load into $c" { kind load docker-image $TorchImage --name $c }
    }
    Ok "image loaded into all clusters"
}

# ---------------------------------------------------------------------------
Step "3. Install Kubeflow Trainer $TrainerVersion (control plane + default runtimes)"
foreach ($c in $AllClusters) {
    $ctx = "kind-$c"
    $installed = helm list -n kubeflow-system --kube-context $ctx -q 2>$null
    if ($installed -contains "kubeflow-trainer") {
        Ok "Trainer already installed on $c - skipping"
    } else {
        Run "helm install trainer on $c" {
            helm install kubeflow-trainer oci://ghcr.io/kubeflow/charts/kubeflow-trainer `
                --namespace kubeflow-system --create-namespace `
                --kube-context $ctx --version $TrainerVersion `
                --set runtimes.defaultEnabled=true
        }
    }
    Run "wait for Trainer on $c" {
        kubectl --context $ctx -n kubeflow-system wait --for=condition=Available deployment --all --timeout=300s
    }
    kubectl --context $ctx get clustertrainingruntimes torch-distributed *> $null
    if ($LASTEXITCODE -ne 0) { Fail "torch-distributed runtime missing on $c" }
    Ok "Trainer ready on $c"
}

# ---------------------------------------------------------------------------
Step "4. Install Kueue $KueueVersion"
$kueueUrl = "https://github.com/kubernetes-sigs/kueue/releases/download/$KueueVersion/manifests.yaml"
foreach ($c in $AllClusters) {
    $ctx = "kind-$c"
    Run "apply Kueue on $c" { kubectl --context $ctx apply --server-side --force-conflicts -f $kueueUrl }
    Run "wait for Kueue on $c" {
        kubectl --context $ctx -n kueue-system wait --for=condition=Available deployment/kueue-controller-manager --timeout=300s
    }
    Ok "Kueue ready on $c"
}

# ---------------------------------------------------------------------------
Step "5. Manager: trimmed Kueue config (only frameworks whose CRDs exist on the workers)"
# Re-save as UTF-8 without BOM - PowerShell/Notepad UTF-16 files silently break the ConfigMap.
$cfgText = Get-Content $ManagerConfig -Raw
[System.IO.File]::WriteAllText((Resolve-Path $ManagerConfig), $cfgText, $Utf8NoBom)

$mctx = "kind-$Manager"
kubectl --context $mctx -n kueue-system delete configmap kueue-manager-config --ignore-not-found | Out-Null
Run "create manager ConfigMap" {
    kubectl --context $mctx -n kueue-system create configmap kueue-manager-config `
        --from-file=controller_manager_config.yaml=$ManagerConfig
}
$live = kubectl --context $mctx -n kueue-system get configmap kueue-manager-config -o yaml
if ($live -match '^\s*- "kubeflow.org/mpijob"' -or $live -match '^\s*- "ray.io/') {
    Fail "manager ConfigMap still lists mpijob/ray frameworks - check $ManagerConfig"
}
Run "restart manager Kueue" { kubectl --context $mctx -n kueue-system rollout restart deployment/kueue-controller-manager }
Run "wait manager Kueue"    { kubectl --context $mctx -n kueue-system rollout status deployment/kueue-controller-manager --timeout=300s }
Ok "manager config applied"

# ---------------------------------------------------------------------------
Step "6. Workers: queues + RBAC for the MultiKueue service account"
foreach ($c in $Workers) {
    $ctx = "kind-$c"
    Run "queues on $c" { kubectl --context $ctx apply -f (Join-Path $ManifestDir "worker-queue-setup.yaml") }
    Run "rbac on $c"   { kubectl --context $ctx apply -f (Join-Path $ManifestDir "worker-rbac.yaml") }
    foreach ($check in @("watch statefulsets", "watch deployments", "create trainjobs.trainer.kubeflow.org", "create workloads.kueue.x-k8s.io")) {
        $args2 = $check.Split(" ")
        $ans = kubectl --context $ctx auth can-i $args2[0] $args2[1] --as=system:serviceaccount:kueue-system:multikueue-sa
        if ($ans -ne "yes") { Fail "multikueue-sa on $c cannot '$check' - check worker-rbac.yaml" }
    }
    Ok "queues + RBAC on $c"
}

# ---------------------------------------------------------------------------
Step "7. Worker kubeconfigs (internal Docker-network address) -> Secrets on manager"
$gi = ".gitignore"
if (-not (Test-Path $gi) -or -not (Select-String -Path $gi -Pattern '^\*\.kubeconfig$' -Quiet)) {
    Add-Content $gi "*.kubeconfig"
    Ok "added *.kubeconfig to .gitignore (these files contain tokens)"
}

foreach ($c in $Workers) {
    $ctx   = "kind-$c"
    $token = kubectl --context $ctx -n kueue-system create token multikueue-sa --duration=8760h
    if ($LASTEXITCODE -ne 0 -or -not $token) { Fail "could not create token on $c" }

    $caLine = kind get kubeconfig --name $c --internal | Select-String "certificate-authority-data:"
    if (-not $caLine) { Fail "could not read CA for $c" }
    $ca     = $caLine.ToString().Split(":", 2)[1].Trim()
    # 127.0.0.1:<port> only works from the Windows host; manager's pod needs the container name.
    $server = "https://$c-control-plane:6443"

    $kc = @"
apiVersion: v1
kind: Config
clusters:
- name: $c
  cluster:
    certificate-authority-data: $ca
    server: $server
users:
- name: $c-multikueue-sa
  user:
    token: $token
contexts:
- name: $c
  context:
    cluster: $c
    user: $c-multikueue-sa
current-context: $c
"@
    $kcPath = Join-Path $PWD "$c.kubeconfig"
    [System.IO.File]::WriteAllText($kcPath, $kc, $Utf8NoBom)

    kubectl --context $mctx -n kueue-system delete secret "$c-secret" --ignore-not-found | Out-Null
    Run "secret $c-secret on manager" {
        kubectl --context $mctx -n kueue-system create secret generic "$c-secret" --from-file=kubeconfig=$kcPath
    }
    Ok "$c-secret created (server $server)"
}

# ---------------------------------------------------------------------------
Step "8. Manager: MultiKueueClusters, MultiKueueConfig, AdmissionCheck, queues"
Run "apply manager-setup.yaml" { kubectl --context $mctx apply -f (Join-Path $ManifestDir "manager-setup.yaml") }
foreach ($c in $Workers) { Wait-Active -Kind "multikueuecluster" -Name $c }
Wait-Active -Kind "admissionchecks" -Name "multikueue-ac"
Wait-Active -Kind "clusterqueues"   -Name "cluster-queue"

# ---------------------------------------------------------------------------
if ($SkipTrainJob) {
    Step "Done - lab rebuilt. Submit a job with:"
    Write-Host "  kubectl --context $mctx apply -f $(Join-Path $ManifestDir 'multikueue-trainjob.yaml')"
    exit 0
}

Step "9. Submit the demo TrainJob to the manager"
kubectl --context $mctx delete trainjob multikueue-hello -n default --ignore-not-found | Out-Null
Run "apply TrainJob" { kubectl --context $mctx apply -f (Join-Path $ManifestDir "multikueue-trainjob.yaml") }

$picked = $null
$deadline = (Get-Date).AddSeconds(120)
while (-not $picked -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    foreach ($c in $Workers) {
        $found = kubectl --context "kind-$c" get trainjob multikueue-hello -n default -o name 2>$null
        if ($found) { $picked = $c; break }
    }
}
if (-not $picked) { Fail "no worker received the TrainJob within 120s - run: kubectl --context $mctx get workloads -n default" }
Ok "MultiKueue placed the TrainJob on $picked"

Write-Host "`nPods on ${picked} (logs vanish once MultiKueue cleans up after completion - read them while Running):"
kubectl --context "kind-$picked" get pods -n default
Write-Host "`nNext:"
Write-Host "  kubectl --context kind-$picked get pods -n default -w"
Write-Host "  kubectl --context kind-$picked logs -n default -l jobset.sigs.k8s.io/jobset-name=multikueue-hello --prefix --tail=-1"
Write-Host "  kubectl --context $mctx get trainjob,workloads -n default   # manager shows Suspended while running, then Complete"