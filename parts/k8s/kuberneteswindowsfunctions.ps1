# This is a temporary file to test dot-sourcing functions stored in separate scripts in a zip file


# Windows defaults, not changed by acs-engine
$global:DockerServiceName = "Docker"
$global:KubeNetwork = "l2bridge"
$global:KubeDnsSearchPath = "svc.cluster.local"


$global:CNIPath = [Io.path]::Combine("$global:KubeDir", "cni")
$global:NetworkMode = "L2Bridge"
$global:CNIConfig = [Io.path]::Combine($global:CNIPath, "config", "`$global:NetworkMode.conf")
$global:CNIConfigPath = [Io.path]::Combine("$global:CNIPath", "config")
$global:WindowsCNIKubeletOptions = @("--cni-bin-dir=$global:CNIPath", "--cni-conf-dir=$global:CNIConfigPath")
$global:HNSModule = [Io.path]::Combine("$global:KubeDir", "hns.psm1")

$global:AzureCNIDir = [Io.path]::Combine("$global:KubeDir", "azurecni")
$global:AzureCNIBinDir = [Io.path]::Combine("$global:AzureCNIDir", "bin")
$global:AzureCNIConfDir = [Io.path]::Combine("$global:AzureCNIDir", "netconf")
$global:AzureCNIKubeletOptions = @("--cni-bin-dir=$global:AzureCNIBinDir", "--cni-conf-dir=$global:AzureCNIConfDir")
$global:AzureCNIEnabled = $false



filter Timestamp {"$(Get-Date -Format o): $_"}

function
Write-Log($message)
{
    $msg = $message | Timestamp
    Write-Output $msg
}

function DownloadFileOverHttp($Url, $DestinationPath)
{
    $secureProtocols = @()
    $insecureProtocols = @([System.Net.SecurityProtocolType]::SystemDefault, [System.Net.SecurityProtocolType]::Ssl3)

    foreach ($protocol in [System.Enum]::GetValues([System.Net.SecurityProtocolType]))
    {
        if ($insecureProtocols -notcontains $protocol)
        {
            $secureProtocols += $protocol
        }
    }
    [System.Net.ServicePointManager]::SecurityProtocol = $secureProtocols

    Invoke-WebRequest $Url -UseBasicParsing -OutFile $DestinationPath -Verbose
    Write-Log "Downloaded file to $DestinationPath"
}

function Get-HnsPsm1()
{
    DownloadFileOverHttp "https://github.com/Microsoft/SDN/raw/master/Kubernetes/windows/hns.psm1" "$global:HNSModule"
}

function Update-WinCNI()
{
    $wincni = "wincni.exe"
    $wincniFile = [Io.path]::Combine($global:CNIPath, $wincni)
    DownloadFileOverHttp "https://github.com/Microsoft/SDN/raw/master/Kubernetes/windows/cni/wincni.exe" $wincniFile
}

function
Update-WindowsPackages()
{
    Update-WinCNI
    Get-HnsPsm1
}



function
Set-VnetPluginMode($mode)
{
    # Sets Azure VNET CNI plugin operational mode.
    $fileName  = [Io.path]::Combine("$global:AzureCNIConfDir", "10-azure.conflist")
    (Get-Content $fileName) | %{$_ -replace "`"mode`":.*", "`"mode`": `"$mode`","} | Out-File -encoding ASCII -filepath $fileName
}

function
Install-VnetPlugins()
{
    # Create CNI directories.
    mkdir $global:AzureCNIBinDir
    mkdir $global:AzureCNIConfDir

    # Download Azure VNET CNI plugins.
    # Mirror from https://github.com/Azure/azure-container-networking/releases
    $zipfile =  [Io.path]::Combine("$global:AzureCNIDir", "azure-vnet.zip")
    Invoke-WebRequest -Uri $global:VNetCNIPluginsURL -OutFile $zipfile
    Expand-Archive -path $zipfile -DestinationPath $global:AzureCNIBinDir
    del $zipfile

    # Windows does not need a separate CNI loopback plugin because the Windows
    # kernel automatically creates a loopback interface for each network namespace.
    # Copy CNI network config file and set bridge mode.
    move $global:AzureCNIBinDir/*.conflist $global:AzureCNIConfDir

    # Enable CNI in kubelet.
    $global:AzureCNIEnabled = $true
}

function
Set-AzureNetworkPlugin()
{
    # Azure VNET network policy requires tunnel (hairpin) mode because policy is enforced in the host.
    Set-VnetPluginMode "tunnel"
}

function
Set-AzureCNIConfig()
{
    # Fill in DNS information for kubernetes.
    $fileName  = [Io.path]::Combine("$global:AzureCNIConfDir", "10-azure.conflist")
    $configJson = Get-Content $fileName | ConvertFrom-Json
    $configJson.plugins.dns.Nameservers[0] = $KubeDnsServiceIp
    $configJson.plugins.dns.Search[0] = $global:KubeDnsSearchPath
    $configJson.plugins.AdditionalArgs[0].Value.ExceptionList[0] = $global:KubeClusterCIDR
    $configJson.plugins.AdditionalArgs[0].Value.ExceptionList[1] = $global:MasterSubnet
    $configJson.plugins.AdditionalArgs[1].Value.DestinationPrefix  = $global:KubeServiceCIDR

    $configJson | ConvertTo-Json -depth 20 | Out-File -encoding ASCII -filepath $fileName
}

function
Set-NetworkConfig
{
    Write-Log "Configuring networking with NetworkPlugin:$global:NetworkPlugin"

    # Configure network policy.
    if ($global:NetworkPlugin -eq "azure") {
        Install-VnetPlugins
        Set-AzureCNIConfig
    }
}

function
Write-KubernetesStartFiles($podCIDR)
{
    mkdir $global:VolumePluginDir 
    $KubeletArgList = $global:KubeletConfigArgs # This is the initial list passed in from acs-engine
    $KubeletArgList += "--node-labels=`$global:KubeletNodeLabels"
    $KubeletArgList += "--hostname-override=`$global:AzureHostname"
    $KubeletArgList += "--volume-plugin-dir=`$global:VolumePluginDir"
    # If you are thinking about adding another arg here, you should be considering pkg/acsengine/defaults-kubelet.go first
    # Only args that need to be calculated or combined with other ones on the Windows agent should be added here.
    

    # Regex to strip version to Major.Minor.Build format such that the following check does not crash for version like x.y.z-alpha
    [regex]$regex = "^[0-9.]+"
    $KubeBinariesVersionStripped = $regex.Matches($global:KubeBinariesVersion).Value
    if ([System.Version]$KubeBinariesVersionStripped -lt [System.Version]"1.8.0")
    {
        # --api-server deprecates from 1.8.0
        $KubeletArgList += "--api-servers=https://`${global:MasterIP}:443"
    }

    # Configure kubelet to use CNI plugins if enabled.
    if ($global:AzureCNIEnabled) {
        $KubeletArgList += $global:AzureCNIKubeletOptions
    } else {
        $KubeletArgList += $global:WindowsCNIKubeletOptions
        $KubeletArgList = $KubeletArgList -replace "kubenet", "cni"
    }

    # Used in WinCNI version of kubeletstart.ps1
    $KubeletArgListStr = ""
    $KubeletArgList | Foreach-Object {
        # Since generating new code to be written to a file, need to escape quotes again
        if ($KubeletArgListStr.length -gt 0)
        {
            $KubeletArgListStr = $KubeletArgListStr + ", "
        }
        $KubeletArgListStr = $KubeletArgListStr + "`"" + $_.Replace("`"`"","`"`"`"`"") + "`""
    }
    $KubeletArgListStr = "@`($KubeletArgListStr`)"

    # Used in Azure-CNI version of kubeletstart.ps1
    $KubeletCommandLine = "c:\k\kubelet.exe " + ($KubeletArgList -join " ")

    $kubeStartStr = @"
`$global:MasterIP = "$MasterIP"
`$global:KubeDnsSearchPath = "svc.cluster.local"
`$global:KubeDnsServiceIp = "$KubeDnsServiceIp"
`$global:MasterSubnet = "$global:MasterSubnet"
`$global:KubeClusterCIDR = "$global:KubeClusterCIDR"
`$global:KubeServiceCIDR = "$global:KubeServiceCIDR"
`$global:KubeBinariesVersion = "$global:KubeBinariesVersion"
`$global:CNIPath = "$global:CNIPath"
`$global:NetworkMode = "$global:NetworkMode"
`$global:ExternalNetwork = "ext"
`$global:CNIConfig = "$global:CNIConfig"
`$global:HNSModule = "$global:HNSModule"
`$global:VolumePluginDir = "$global:VolumePluginDir"
`$global:NetworkPlugin="$global:NetworkPlugin"
`$global:KubeletNodeLabels="$global:KubeletNodeLabels"

"@

    if ($global:NetworkPlugin -eq "azure") {
        $global:KubeNetwork = "azure"
        $kubeStartStr += @"
Write-Host "NetworkPlugin azure, starting kubelet."

# Turn off Firewall to enable pods to talk to service endpoints. (Kubelet should eventually do this)
netsh advfirewall set allprofiles state off
# startup the service

# Find if the primary external switch network exists. If not create one.
# This is done only once in the lifetime of the node
`$hnsNetwork = Get-HnsNetwork | ? Name -EQ `$global:ExternalNetwork
if (!`$hnsNetwork)
{
    Write-Host "Creating a new hns Network"
    ipmo `$global:HNSModule
    # Fixme : use a smallest range possible, that will not collide with any pod space
    New-HNSNetwork -Type `$global:NetworkMode -AddressPrefix "192.168.255.0/30" -Gateway "192.168.255.1" -Name `$global:ExternalNetwork -Verbose
}

# Find if network created by CNI exists, if yes, remove it
# This is required to keep the network non-persistent behavior
# Going forward, this would be done by HNS automatically during restart of the node

`$hnsNetwork = Get-HnsNetwork | ? Name -EQ $global:KubeNetwork
if (`$hnsNetwork)
{
    # Cleanup all containers
    docker ps -q | foreach {docker rm `$_ -f}

    Write-Host "Cleaning up old HNS network found"
    Remove-HnsNetwork `$hnsNetwork
    # Kill all cni instances & stale data left by cni
    # Cleanup all files related to cni
    `$cnijson = [io.path]::Combine("$global:KubeDir", "azure-vnet-ipam.json")
    if ((Test-Path `$cnijson))
    {
        Remove-Item `$cnijson
    }
    `$cnilock = [io.path]::Combine("$global:KubeDir", "azure-vnet-ipam.lock")
    if ((Test-Path `$cnilock))
    {
        Remove-Item `$cnilock
    }
    taskkill /IM azure-vnet-ipam.exe /f

    `$cnijson = [io.path]::Combine("$global:KubeDir", "azure-vnet.json")
    if ((Test-Path `$cnijson))
    {
        Remove-Item `$cnijson
    }
    `$cnilock = [io.path]::Combine("$global:KubeDir", "azure-vnet.lock")
    if ((Test-Path `$cnilock))
    {
        Remove-Item `$cnilock
    }
    taskkill /IM azure-vnet.exe /f
}

# Restart Kubeproxy, which would wait, until the network is created
Restart-Service Kubeproxy

$KubeletCommandLine

"@
    } 
    else  # using WinCNI. TODO: If WinCNI support is removed, then delete this as dead code later
    {
        $kubeStartStr += @"

function
Get-DefaultGateway(`$CIDR)
{
    return `$CIDR.substring(0,`$CIDR.lastIndexOf(".")) + ".1"
}

function
Get-PodCIDR()
{
    `$podCIDR = c:\k\kubectl.exe --kubeconfig=c:\k\config get nodes/`$(`$env:computername.ToLower()) -o custom-columns=podCidr:.spec.podCIDR --no-headers
    return `$podCIDR
}

function
Test-PodCIDR(`$podCIDR)
{
    return `$podCIDR.length -gt 0
}

function
Update-CNIConfig(`$podCIDR, `$masterSubnetGW)
{
    `$jsonSampleConfig =
"{
    ""cniVersion"": ""0.2.0"",
    ""name"": ""<NetworkMode>"",
    ""type"": ""wincni.exe"",
    ""master"": ""Ethernet"",
    ""capabilities"": { ""portMappings"": true },
    ""ipam"": {
        ""environment"": ""azure"",
        ""subnet"":""<PODCIDR>"",
        ""routes"": [{
        ""GW"":""<PODGW>""
        }]
    },
    ""dns"" : {
    ""Nameservers"" : [ ""<NameServers>"" ],
    ""Search"" : [ ""<Cluster DNS Suffix or Search Path>"" ]
    },
    ""AdditionalArgs"" : [
    {
        ""Name"" : ""EndpointPolicy"", ""Value"" : { ""Type"" : ""OutBoundNAT"", ""ExceptionList"": [ ""<ClusterCIDR>"", ""<MgmtSubnet>"" ] }
    },
    {
        ""Name"" : ""EndpointPolicy"", ""Value"" : { ""Type"" : ""ROUTE"", ""DestinationPrefix"": ""<ServiceCIDR>"", ""NeedEncap"" : true }
    }
    ]
}"

    `$configJson = ConvertFrom-Json `$jsonSampleConfig
    `$configJson.name = `$global:NetworkMode.ToLower()
    `$configJson.ipam.subnet=`$podCIDR
    `$configJson.ipam.routes[0].GW = `$masterSubnetGW
    `$configJson.dns.Nameservers[0] = `$global:KubeDnsServiceIp
    `$configJson.dns.Search[0] = `$global:KubeDnsSearchPath

    `$configJson.AdditionalArgs[0].Value.ExceptionList[0] = `$global:KubeClusterCIDR
    `$configJson.AdditionalArgs[0].Value.ExceptionList[1] = `$global:MasterSubnet
    `$configJson.AdditionalArgs[1].Value.DestinationPrefix  = `$global:KubeServiceCIDR

    if (Test-Path `$global:CNIConfig)
    {
        Clear-Content -Path `$global:CNIConfig
    }

    Write-Host "Generated CNI Config [`$configJson]"

    Add-Content -Path `$global:CNIConfig -Value (ConvertTo-Json `$configJson -Depth 20)
}

try
{
    `$masterSubnetGW = Get-DefaultGateway `$global:MasterSubnet
    `$podCIDR=Get-PodCIDR
    `$podCidrDiscovered=Test-PodCIDR(`$podCIDR)

    # if the podCIDR has not yet been assigned to this node, start the kubelet process to get the podCIDR, and then promptly kill it.
    if (-not `$podCidrDiscovered)
    {
        `$argList = $KubeletArgListStr

        `$process = Start-Process -FilePath c:\k\kubelet.exe -PassThru -ArgumentList `$argList

        # run kubelet until podCidr is discovered
        Write-Host "waiting to discover pod CIDR"
        while (-not `$podCidrDiscovered)
        {
            Write-Host "Sleeping for 10s, and then waiting to discover pod CIDR"
            Start-Sleep 10

            `$podCIDR=Get-PodCIDR
            `$podCidrDiscovered=Test-PodCIDR(`$podCIDR)
        }

        # stop the kubelet process now that we have our CIDR, discard the process output
        `$process | Stop-Process | Out-Null
    }

    # Turn off Firewall to enable pods to talk to service endpoints. (Kubelet should eventually do this)
    netsh advfirewall set allprofiles state off

    # startup the service
    `$hnsNetwork = Get-HnsNetwork | ? Name -EQ `$global:NetworkMode.ToLower()

    if (`$hnsNetwork)
    {
        # Kubelet has been restarted with existing network.
        # Cleanup all containers
        docker ps -q | foreach {docker rm `$_ -f}
        # cleanup network
        Write-Host "Cleaning up old HNS network found"
        Remove-HnsNetwork `$hnsNetwork
        Start-Sleep 10
    }

    Write-Host "Creating a new hns Network"
    ipmo `$global:HNSModule

    `$hnsNetwork = New-HNSNetwork -Type `$global:NetworkMode -AddressPrefix `$podCIDR -Gateway `$masterSubnetGW -Name `$global:NetworkMode.ToLower() -Verbose
    # New network has been created, Kubeproxy service has to be restarted
    Restart-Service Kubeproxy

    Start-Sleep 10
    # Add route to all other POD networks
    Update-CNIConfig `$podCIDR `$masterSubnetGW

    $KubeletCommandLine
}
catch
{
    Write-Error `$_
}

"@
    } # end else using WinCNI.

    $kubeStartStr | Out-File -encoding ASCII -filepath $global:KubeletStartFile

    $kubeProxyStartStr = @"
`$env:KUBE_NETWORK = "$global:KubeNetwork"
`$global:NetworkMode = "$global:NetworkMode"
`$global:HNSModule = "$global:HNSModule"
`$hnsNetwork = Get-HnsNetwork | ? Name -EQ $global:KubeNetwork
while (!`$hnsNetwork)
{
    Write-Host "Waiting for Network [$global:KubeNetwork] to be created . . ."
    Start-Sleep 10
    `$hnsNetwork = Get-HnsNetwork | ? Name -EQ $global:KubeNetwork
}

#
# cleanup the persisted policy lists
#
ipmo `$global:HNSModule
Get-HnsPolicyList | Remove-HnsPolicyList

$global:KubeDir\kube-proxy.exe --v=3 --proxy-mode=kernelspace --hostname-override=$env:computername --kubeconfig=$global:KubeDir\config
"@

    $kubeProxyStartStr | Out-File -encoding ASCII -filepath $global:KubeProxyStartFile
}

function
New-NSSMService
{
    # setup kubelet
    c:\k\nssm install Kubelet C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
    c:\k\nssm set Kubelet AppDirectory $global:KubeDir
    c:\k\nssm set Kubelet AppParameters $global:KubeletStartFile
    c:\k\nssm set Kubelet DisplayName Kubelet
    c:\k\nssm set Kubelet Description Kubelet
    c:\k\nssm set Kubelet Start SERVICE_AUTO_START
    c:\k\nssm set Kubelet ObjectName LocalSystem
    c:\k\nssm set Kubelet Type SERVICE_WIN32_OWN_PROCESS
    c:\k\nssm set Kubelet AppThrottle 1500
    c:\k\nssm set Kubelet AppStdout C:\k\kubelet.log
    c:\k\nssm set Kubelet AppStderr C:\k\kubelet.err.log
    c:\k\nssm set Kubelet AppStdoutCreationDisposition 4
    c:\k\nssm set Kubelet AppStderrCreationDisposition 4
    c:\k\nssm set Kubelet AppRotateFiles 1
    c:\k\nssm set Kubelet AppRotateOnline 1
    c:\k\nssm set Kubelet AppRotateSeconds 86400
    c:\k\nssm set Kubelet AppRotateBytes 1048576

    # setup kubeproxy
    c:\k\nssm install Kubeproxy C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
    c:\k\nssm set Kubeproxy AppDirectory $global:KubeDir
    c:\k\nssm set Kubeproxy AppParameters $global:KubeProxyStartFile
    c:\k\nssm set Kubeproxy DisplayName Kubeproxy
    c:\k\nssm set Kubeproxy DependOnService Kubelet
    c:\k\nssm set Kubeproxy Description Kubeproxy
    c:\k\nssm set Kubeproxy Start SERVICE_AUTO_START
    c:\k\nssm set Kubeproxy ObjectName LocalSystem
    c:\k\nssm set Kubeproxy Type SERVICE_WIN32_OWN_PROCESS
    c:\k\nssm set Kubeproxy AppThrottle 1500
    c:\k\nssm set Kubeproxy AppStdout C:\k\kubeproxy.log
    c:\k\nssm set Kubeproxy AppStderr C:\k\kubeproxy.err.log
    c:\k\nssm set Kubeproxy AppRotateFiles 1
    c:\k\nssm set Kubeproxy AppRotateOnline 1
    c:\k\nssm set Kubeproxy AppRotateSeconds 86400
    c:\k\nssm set Kubeproxy AppRotateBytes 1048576
}