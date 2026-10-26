# vm-watchdog.ps1 - starts any listed VM that is not running, and logs every restart.
# Put it in C:\VMwatchdog\ and edit the $vms list. Run it every 5 minutes from Task Scheduler,
# as the SAME Windows account that normally runs the VMs.
$vmrun = "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe"
$vms = @(
    "D:\VMs\shares1\shares1.vmx"        # <-- change to the real .vmx path of the VM on this host
)
$log = "C:\VMwatchdog\watchdog.log"

New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
$running = (& $vmrun -T ws list 2>&1 | Out-String)

foreach ($vm in $vms) {
    if (-not (Test-Path $vm)) { "$(Get-Date -Format s) ERROR: $vm not found" | Add-Content $log; continue }
    if ($running -notlike "*$vm*") {
        "$(Get-Date -Format s) $vm not running - starting" | Add-Content $log
        $out = (& $vmrun -T ws start $vm nogui 2>&1 | Out-String).Trim()
        "$(Get-Date -Format s) start result: $out" | Add-Content $log
    }
}
