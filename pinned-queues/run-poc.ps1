<#
.SYNOPSIS
  Option 1 PoC: pinned queues. The queue a job names decides which worker cluster runs it.

.DESCRIPTION
  Assumes the base lab is already running (manager + worker-a + worker-b, Trainer, Kueue,
  MultiKueue connected, user-queue working). Run from this folder:

    .\run-poc.ps1              # set up routes, submit one job to each worker, show placement
    .\run-poc.ps1 -Extra       # also submit a 2nd job to worker-b while worker-a has room
    .\run-poc.ps1 -Status      # just show where everything is right now
    .\run-poc.ps1 -Cleanup     # delete the PoC jobs and pinned routes (base lab untouched)
#>
param(
    [switch]$Extra,
    [switch]$Status,
    [switch]$Cleanup
)

$ErrorActionPreference = "Continue"
Set-Location $PSScriptRoot

$Manager = "kind-manager"
$Workers = @("kind-worker-a", "kind-worker-b")
$Jobs    = @("pinned-job-a", "pinned-job-b", "pinned-job-b2")

function Step($m) { Write-Host "`n==== $m ====" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  OK   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  WARN $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  FAIL $m" -ForegroundColor Red; exit 1 }

function Run([string]$What, [scriptblock]$Cmd) {
    & $Cmd
    if ($LASTEXITCODE -ne 0) { Fail "$What (exit code $LASTEXITCODE)" }
}

function Show-Placement {
    Step "Where each job is"
    Write-Host "Manager (jobs show Suspended here by design; the worker copy is the one that runs):"
    kubectl --context $Manager get trainjob,workloads -n default
    foreach ($w in $Workers) {
        Write-Host "`n$w :" -ForegroundColor Cyan
        kubectl --context $w get trainjob,pods -n default
    }
    Write-Host "`nWorker ClusterQueue usage:" -ForegroundColor Cyan
    foreach ($w in $Workers) {
        $used = kubectl --context $w get clusterqueue cluster-queue `
            -o jsonpath="{.status.reservingWorkloads} workloads, cpu={.status.flavorsUsage[0].resources[?(@.name=='cpu')].total}"
        Write-Host "  $w : $used"
    }
}

function Wait-Active([string]$Kind, [string]$Name, [int]$TimeoutSec = 120) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $s = kubectl --context $Manager get $Kind $Name `
            -o jsonpath="{.status.conditions[?(@.type=='Active')].status}" 2>$null
        if ($s -eq "True") { Ok "$Kind/$Name is Active"; return }
        Start-Sleep -Seconds 3
    }
    $msg = kubectl --context $Manager get $Kind $Name `
        -o jsonpath="{.status.conditions[?(@.type=='Active')].message}" 2>$null
    Fail "$Kind/$Name not Active after ${TimeoutSec}s: $msg"
}

function Wait-Landed([string]$Job, [string]$Expected, [int]$TimeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        foreach ($w in $Workers) {
            $found = kubectl --context $w get trainjob $Job -n default -o name 2>$null
            if ($found) {
                $short = $w -replace '^kind-', ''
                if ($short -eq $Expected) { Ok "$Job landed on $short (as pinned)" }
                else { Warn "$Job landed on $short but was pinned to $Expected" }
                return
            }
        }
        Start-Sleep -Seconds 3
    }
    Warn "$Job has not reached any worker after ${TimeoutSec}s - run: kubectl --context $Manager get workloads -n default"
}

# ---------------------------------------------------------------------------
if ($Status) { Show-Placement; exit 0 }

if ($Cleanup) {
    Step "Cleanup"
    foreach ($j in $Jobs) { kubectl --context $Manager delete trainjob $j -n default --ignore-not-found }
    kubectl --context $Manager delete -f .\manager-pinned-queues.yaml --ignore-not-found
    foreach ($w in $Workers) { kubectl --context $w delete -f .\worker-pinned-queues.yaml --ignore-not-found }
    Ok "PoC removed; base lab (user-queue, cluster-queue, multikueue-ac) untouched"
    exit 0
}

# ---------------------------------------------------------------------------
Step "0. Preflight"
foreach ($f in @("manager-pinned-queues.yaml", "worker-pinned-queues.yaml", "trainjob-to-worker-a.yaml", "trainjob-to-worker-b.yaml")) {
    if (-not (Test-Path $f)) { Fail "missing $f (run this script from the pinned-queues folder)" }
}
foreach ($c in @("worker-a", "worker-b")) {
    $s = kubectl --context $Manager get multikueuecluster $c -o jsonpath="{.status.conditions[?(@.type=='Active')].status}" 2>$null
    if ($s -ne "True") { Fail "MultiKueueCluster $c not connected - fix the base lab first" }
}
kubectl --context $Manager get resourceflavor default-flavor *> $null
if ($LASTEXITCODE -ne 0) { Fail "ResourceFlavor default-flavor missing on manager - apply manager-setup.yaml first" }

# Pinned routes rely on the default (AllAtOnce) dispatcher. An external dispatcher would
# make MultiKueue wait for someone to nominate a cluster, and nothing would run.
$cfg = kubectl --context $Manager -n kueue-system get configmap kueue-manager-config -o yaml 2>$null
if ($cfg -match 'dispatcherName:\s*(\S+)' -and $Matches[1] -notmatch 'all-at-once') {
    Fail "manager Kueue config sets dispatcherName=$($Matches[1]). Remove it (Option 2 setting) and restart Kueue before this PoC."
}
Ok "base lab ready, default dispatcher in use"

# ---------------------------------------------------------------------------
Step "1. Pinned routes on manager"
Run "apply manager-pinned-queues.yaml" { kubectl --context $Manager apply -f .\manager-pinned-queues.yaml }
Wait-Active "admissionchecks" "ac-worker-a"
Wait-Active "admissionchecks" "ac-worker-b"
Wait-Active "clusterqueues"   "cq-worker-a"
Wait-Active "clusterqueues"   "cq-worker-b"

Step "2. Matching LocalQueues on both workers"
foreach ($w in $Workers) {
    Run "apply worker-pinned-queues.yaml on $w" { kubectl --context $w apply -f .\worker-pinned-queues.yaml }
}
Ok "queue-worker-a and queue-worker-b exist on both workers"

# ---------------------------------------------------------------------------
Step "3. Submit the same job, once per worker"
foreach ($j in $Jobs) { kubectl --context $Manager delete trainjob $j -n default --ignore-not-found | Out-Null }

Run "submit pinned-job-a" { kubectl --context $Manager apply -f .\trainjob-to-worker-a.yaml }
Wait-Landed "pinned-job-a" "worker-a"

Run "submit pinned-job-b" { kubectl --context $Manager apply -f .\trainjob-to-worker-b.yaml }
Wait-Landed "pinned-job-b" "worker-b"

if ($Extra) {
    Step "4. Extra: 2nd job forced to worker-b while worker-a has room"
    Run "submit pinned-job-b2" { kubectl --context $Manager apply -f .\trainjob-extra-to-worker-b.yaml }
    Wait-Landed "pinned-job-b2" "worker-b"
}

Show-Placement

Write-Host "`nJobs sleep 300s. Read logs while they run:"
Write-Host "  kubectl --context kind-worker-b logs -n default -l jobset.sigs.k8s.io/jobset-name=pinned-job-b --prefix"
Write-Host "Re-check any time:  .\run-poc.ps1 -Status"
Write-Host "Remove the PoC:     .\run-poc.ps1 -Cleanup"
