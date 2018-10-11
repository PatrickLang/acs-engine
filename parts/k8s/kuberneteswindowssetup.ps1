<#
    .SYNOPSIS
        Provisions VM as a Kubernetes agent.

    .DESCRIPTION
        Provisions VM as a Kubernetes agent.
        
        The parameters passed in are required, and will vary per-deployment.

        Notes on modifying this file:
        - This file extension is PS1, but it is actually used as a template from pkg/acsengine/template_generator.go
        - All of the lines that have braces in them will be modified. Please do not change them here, change them in the Go sources
        - Single quotes are forbidden, they are reserved to delineate the different members for the ARM template concat() call
#>
[CmdletBinding(DefaultParameterSetName="Standard")]
param(
    [string]
    [ValidateNotNullOrEmpty()]
    $MasterIP,

    [parameter()]
    [ValidateNotNullOrEmpty()]
    $KubeDnsServiceIp,

    [parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    $MasterFQDNPrefix,

    [parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    $Location,

    [parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    $AgentKey,

    [parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    $AADClientId,

    [parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    $AADClientSecret
)



# These globals will not change between nodes in the same cluster, so they are not
# passed as powershell parameters

## Certificates generated by acs-engine
$global:CACertificate = "{{WrapAsParameter "caCertificate"}}"
$global:AgentCertificate = "{{WrapAsParameter "clientCertificate"}}"

## Download sources provided by acs-engine
$global:KubeBinariesSASURL = "{{WrapAsParameter "kubeBinariesSASURL"}}"
$global:WindowsPackageSASURLBase = "{{WrapAsParameter "windowsPackageSASURLBase"}}"
$global:KubeBinariesVersion = "{{WrapAsParameter "kubeBinariesVersion"}}"

## VM configuration passed by Azure
$global:WindowsTelemetryGUID = "{{WrapAsParameter "windowsTelemetryGUID"}}"
$global:TenantId = "{{WrapAsVariable "tenantID"}}"
$global:SubscriptionId = "{{WrapAsVariable "subscriptionId"}}"
$global:ResourceGroup = "{{WrapAsVariable "resourceGroup"}}"
$global:VmType = "{{WrapAsVariable "vmType"}}"
$global:SubnetName = "{{WrapAsVariable "subnetName"}}"
$global:MasterSubnet = "{{WrapAsParameter "masterSubnet"}}"
$global:SecurityGroupName = "{{WrapAsVariable "nsgName"}}"
$global:VNetName = "{{WrapAsVariable "virtualNetworkName"}}"
$global:RouteTableName = "{{WrapAsVariable "routeTableName"}}"
$global:PrimaryAvailabilitySetName = "{{WrapAsVariable "primaryAvailabilitySetName"}}"
$global:PrimaryScaleSetName = "{{WrapAsVariable "primaryScaleSetName"}}"

$global:KubeClusterCIDR = "{{WrapAsParameter "kubeClusterCidr"}}"
$global:KubeServiceCIDR = "{{WrapAsParameter "kubeServiceCidr"}}"
$global:KubeletNodeLabels = "{{GetAgentKubernetesLabels . "',variables('labelResourceGroup'),'"}}"
$global:KubeletConfigArgs = @( {{GetKubeletConfigKeyValsPsh .KubernetesConfig }} )

$global:UseManagedIdentityExtension = "{{WrapAsVariable "useManagedIdentityExtension"}}"
$global:UserAssignedClientID = "{{WrapAsVariable "userAssignedClientID"}}"
$global:UseInstanceMetadata = "{{WrapAsVariable "useInstanceMetadata"}}"

$global:LoadBalancerSku = "{{WrapAsVariable "loadBalancerSku"}}"
$global:ExcludeMasterFromStandardLB = "{{WrapAsVariable "excludeMasterFromStandardLB"}}"


# Windows defaults, not changed by acs-engine
$global:KubeDir = "c:\k"
$global:HNSModule = [Io.path]::Combine("$global:KubeDir", "hns.psm1")

$global:KubeDnsSearchPath = "svc.cluster.local"

$global:CNIPath = [Io.path]::Combine("$global:KubeDir", "cni")
$global:NetworkMode = "L2Bridge"
$global:CNIConfig = [Io.path]::Combine($global:CNIPath, "config", "`$global:NetworkMode.conf")
$global:CNIConfigPath = [Io.path]::Combine("$global:CNIPath", "config")


$global:AzureCNIDir = [Io.path]::Combine("$global:KubeDir", "azurecni")
$global:AzureCNIBinDir = [Io.path]::Combine("$global:AzureCNIDir", "bin")
$global:AzureCNIConfDir = [Io.path]::Combine("$global:AzureCNIDir", "netconf")

# Azure cni configuration
# $global:NetworkPolicy = "{{WrapAsParameter "networkPolicy"}}" # BUG: unused
$global:NetworkPlugin = "{{WrapAsParameter "networkPlugin"}}"
$global:VNetCNIPluginsURL = "{{WrapAsParameter "vnetCniWindowsPluginsURL"}}"

# Base64 representation of ZIP archive
$zippedFiles = "{{ GetKubernetesWindowsAgentFunctions }}"

# Extract ZIP from script
[io.file]::WriteAllBytes("scripts.zip", [System.Convert]::FromBase64String($zippedFiles))
Expand-Archive scripts.zip -DestinationPath "C:\\AzureData\\"

# Dot-source contents of zip. This should match the list in template_generator.go GetKubernetesWindowsAgentFunctions
. c:\AzureData\k8s\kuberneteswindowsfunctions.ps1
. c:\AzureData\k8s\windowsconfigfunc.ps1
. c:\AzureData\k8s\windowskubeletfunc.ps1
. c:\AzureData\k8s\windowscnifunc.ps1
. c:\AzureData\k8s\windowsazurecnifunc.ps1

try
{
    # Set to false for debugging.  This will output the start script to
    # c:\AzureData\CustomDataSetupScript.log, and then you can RDP
    # to the windows machine, and run the script manually to watch
    # the output.
    if ($false) { # BUGBUG: revert this to $false before merging back to master
        Write-Log "Provisioning $global:DockerServiceName... with IP $MasterIP"

        Write-Log "apply telemetry data setting"
        Set-TelemetrySetting -WindowsTelemetryGUID $global:WindowsTelemetryGUID

        Write-Log "resize os drive if possible"
        Resize-OSDrive

        Write-Log "download kubelet binaries and unzip"
        Get-KubeBinaries -KubeBinariesSASURL $global:KubeBinariesSASURL

        Write-Log "Write Azure cloud provider config"
        Write-AzureConfig `
            -KubeDir $global:KubeDir `
            -AADClientId $AADClientId `
            -AADClientSecret $AADClientSecret `
            -TenantId $global:TenantId `
            -SubscriptionId $global:SubscriptionId `
            -ResourceGroup $global:ResourceGroup `
            -Location $Location `
            -VmType $global:VmType `
            -SubnetName $global:SubnetName `
            -SecurityGroupName $global:SecurityGroupName `
            -VNetName $global:VNetName `
            -RouteTableName $global:RouteTableName `
            -PrimaryAvailabilitySetName $global:PrimaryAvailabilitySetName `
            -PrimaryScaleSetName $global:PrimaryScaleSetName `
            -UseManagedIdentityExtension $global:UseManagedIdentityExtension `
            -UserAssignedClientID $global:UserAssignedClientID `
            -UseInstanceMetadata $global:UseInstanceMetadata `
            -LoadBalancerSku $global:LoadBalancerSku `
            -ExcludeMasterFromStandardLB $global:ExcludeMasterFromStandardLB

        Write-Log "Write ca root"
        Write-CACert -CACertificate $global:CACertificate `
                     -KubeDir $global:KubeDir

        Write-Log "Write kube config"
        Write-KubeConfig -CACertificate $global:CACertificate `
                         -KubeDir $global:KubeDir `
                         -MasterFQDNPrefix $MasterFQDNPrefix `
                         -MasterIP $MasterIP `
                         -AgentKey $AgentKey `
                         -AgentCertificate $global:AgentCertificate


        Write-Log "Create the Pause Container kubletwin/pause"
        New-InfraContainer -KubeDir $global:KubeDir

        Write-Log "Configuring networking with NetworkPlugin:$global:NetworkPlugin"

        # Configure network policy.
        if ($global:NetworkPlugin -eq "azure") {
            Install-VnetPlugins -AzureCNIConfDir $global:AzureCNIConfDir `
                                -AzureCNIBinDir $global:AzureCNIBinDir `
                                -VNetCNIPluginsURL $global:VNetCNIPluginsURL
            Set-AzureCNIConfig -AzureCNIConfDir $global:AzureCNIConfDir `
                               -KubeDnsSearchPath $global:KubeDnsSearchPath `
                               -KubeClusterCIDR $global:KubeClusterCIDR `
                               -MasterSubnet $global:MasterSubnet `
                               -KubeServiceCIDR $global:KubeServiceCIDR
        } elseif ($global:NetworkPlugin -eq "kubenet") {
            Update-WinCNI -CNIPath $global:CNIPath
            Get-HnsPsm1 -HNSModule $global:HNSModule
        }

        Write-Log "write kubelet startfile with pod CIDR of $podCIDR"
        Install-KubernetesServices `
            -KubeletConfigArgs $global:KubeletConfigArgs `
            -KubeBinariesVersion $global:KubeBinariesVersion `
            -NetworkPlugin $global:NetworkPlugin `
            -NetworkMode $global:NetworkMode `
            -KubeDir $global:KubeDir `
            -AzureCNIBinDir $global:AzureCNIBinDir `
            -AzureCNIConfDir $global:AzureCNIConfDir `
            -CNIPath $global:CNIPath `
            -CNIConfig $global:CNIConfig `
            -CNIConfigPath $global:CNIConfigPath `
            -MasterIP $MasterIP `
            -KubeDnsServiceIp $KubeDnsServiceIp `
            -MasterSubnet $global:MasterSubnet `
            -KubeClusterCIDR $global:KubeClusterCIDR `
            -KubeServiceCIDR $global:KubeServiceCIDR `
            -HNSModule $global:HNSModule `
            -KubeletNodeLabels $global:KubeletNodeLabels

        Write-Log "Disable Internet Explorer compat mode and set homepage"
        Set-Explorer

        Write-Log "Start preProvisioning script"
        PREPROVISION_EXTENSION

        Write-Log "Setup Complete, reboot computer"
        Restart-Computer
    }
    else
    {
        # keep for debugging purposes
        Write-Log ".\CustomDataSetupScript.ps1 -MasterIP $MasterIP -KubeDnsServiceIp $KubeDnsServiceIp -MasterFQDNPrefix $MasterFQDNPrefix -Location $Location -AgentKey $AgentKey -AADClientId $AADClientId -AADClientSecret $AADClientSecret"
    }
}
catch
{
    Write-Error $_
}
