# using API Management as container / service locator

When starting with Function containerization, we wired up containers 1:1 with fixed ports to Service Fabrics / VM scale sets load balancer and health probes. This is OK for a few containers but grows into a real headache when scaling into a Microservice environment. We even had to lift the port limit of the NLB in our subscription when we crossed the 20 ports mark.

## basic approach

A container can also be deployed to Service Fabric without fixed port assignment:

```docker-compose.yml``` before with fixed port:

```yml
services:
  webhost:
    deploy:
      replicas: 2
    environment:
      BuildNumber: '42'
      ImageSource: functions.myfunctionapp:42
    image: mycompanycr.azurecr.io/functions.myfunctionapp:42
    ports:
    - 28010:80/tcp
version: '3.0'
```

```docker-compose.yml``` after w/o fixed port:

```yml
services:
  webhost:
    deploy:
      replicas: 2
    environment:
      BuildNumber: '42'
      ImageSource: functions.myfunctionapp:42
    image: mycompanycr.azurecr.io/functions.myfunctionapp:42
    ports:
    - 80/http
version: '3.0'
```

> ```/http``` suffix is required so that Service Fabric management endpoints returns the correct URI to API Management. But it seems this syntax is not supported by ```docker-compose combine``` so I had to tweak the compose file after this step in CI/CD.

Service Fabric will assign a port itself for each container started on a node. Only the Service Fabric management endpoint then knows the port assignment.

To establish a connection between API Management and the Service Fabric management endpoint, Azure PowerShell cmdlet [New-AzureRmApiManagementBackendServiceFabric](https://docs.microsoft.com/en-us/powershell/module/azurerm.apimanagement/new-azurermapimanagementbackendservicefabric) can be used.

 API Management policies need to be adjusted: [set-backend-service](https://docs.microsoft.com/en-us/azure/api-management/api-management-transformation-policies#SetBackendService) is added to resolve from the containers Service Fabric service name to an URI on a node:

```xml
...
<set-backend-service backend-id="sfbackend" sf-resolve-condition="@(context.LastError?.Reason == "BackendConnectionFailure")" sf-service-instance-name="fabric:/Functions-MyFunctionApp/webhost" />
<rewrite-uri template="/api/getserviceinfo" copy-unmatched-params="true" />
...
```

> ```backend-id="sfbackend"``` needs to relate to the backend id create with ```New-AzureRmApiManagementBackendServiceFabric```.

## gotchas and the complete script

Using ```New-AzureRmApiManagementBackendServiceFabric``` seemed pretty straight forward. However in reality, when breaking up the connection or replacing the certificate, these 2 objects reference each other in API Management and one cannot be without the other.

To exchange connection and certificate while in operation, I chose to always create a new certificate (suffixed with a timestamp) and a new backend entity (as well suffixed), wire them up, put the new backend id into an API Management Named Value to be used by policies and then afterwards removing the obsolete certificates and backend objects:

```configureApiManagement2Cluster.ps1```:

```PowerShell
# random character combination generator for the certificate password
function Get-RandomCharacters($length, $characters) { 
    $random = 1..$length | ForEach-Object { Get-Random -Maximum $characters.length }
    $private:ofs = "" # set ouput field separator
    return [String]$characters[$random]
}

# creates a new APIM to SF client certificate
function New-ClientCertificate() {
    param(
        [string] [Parameter(Mandatory = $true)] $Instance,
        [string] [Parameter(Mandatory = $true)] $Password,
        [string] [Parameter(Mandatory = $true)] $CertName
    )

    $SecurePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $CertFileFullPath = $(Join-Path $PSScriptRoot "$CertName.pfx")

    $subject = "CN=SF Cluster " + $Instance + " APIM Client Auth"
    $friendlyName = $CertName

    # delete existing certificate in local store
    Get-ChildItem Cert:\CurrentUser\My |
        ? {$_.Subject -eq $subject} |
        % {Remove-Item $_.PSPath}

    Get-Item $CertFileFullPath -ErrorAction SilentlyContinue | Remove-Item

    # runs only on Windows 10 or Windows Server 2016!
    $NewCert = New-SelfSignedCertificate -Type Custom -Subject $subject -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 2048 -CertStoreLocation "Cert:\CurrentUser\My" -FriendlyName $friendlyName
    Export-PfxCertificate -FilePath $CertFileFullPath -Password $SecurePassword -Cert $NewCert

    return $NewCert
}

# INIT
$Instance = "PROD"
$TimestampSuffix = (Get-Date -Format u) -Replace "[:\-\s]", ""
$ResourceGroupName = "myResourceGroup" + $Instance
$ApiMServiceName = "myAPIMInstance" + $Instance
$ApiMBackendIdPrefix = "sfcluster"
$ApiMBackendId = $ApiMBackendIdPrefix + $TimestampSuffix
$ApiMBackendTitle = "Service Fabric " + $Instance + " created " + $TimestampSuffix
$ApiMNamedValue = "SFCLUSTER_BACKENDID"

$ctx = New-AzureRmApiManagementContext -ResourceGroupName $ResourceGroupName -ServiceName $ApiMServiceName

# --------------------------------------------------------------------------------------------------------------
Write-Host "create dedicated APIM>SF certificate"
$certPwd = Get-RandomCharacters -length 20 -characters "abcdefghiklmnoprstuvwxyzABCDEFGHKLMNOPRSTUVWXYZ1234567890!§$%&/()=?}][{@#*+"
$certPwd
$certName = "SFAPIM" + $Instance + $TimestampSuffix
$certSubject = "CN=Cluster" + $Instance + " APIM Client Auth"
Get-Item $("SFAPIM" + $Instance) -ErrorAction SilentlyContinue | Remove-Item
$certData = New-ClientCertificate -Subject $certSubject -Password $certPwd -CertName $certName
$certFile = $certData[0]
$cert = $certData[1]

Write-Host "add certificate to API Management"
New-AzureRmApiManagementCertificate -Context $ctx -CertificateId $certName `
    -PfxFilePath $certFile.FullName -PfxPassword $certPwd -Verbose

# --------------------------------------------------------------------------------------------------------------
Read-Host "CHECK-POINT: before Service Fabric certificate upload"

Write-Host "add certificate to clusters"
$clusters = (Get-AzureRmServiceFabricCluster -ResourceGroupName $ResourceGroupName)

$mgmtEndpoints = @()
$serverCertThumbPrints = @()

foreach ($cluster in $clusters) {
    Write-Host " " $cluster.Name "..."
    $mgmtEndpoints += $cluster.ManagementEndpoint
    $serverCertThumbPrints += $cluster.Certificate.Thumbprint
    Add-AzureRmServiceFabricClientCertificate -ResourceGroupName $ResourceGroupName -Name $cluster.Name -Thumbprint $cert.Thumbprint
}

Write-Host "Management Endpoints found:"
$mgmtEndpoints
$serverCertThumbPrints


# --------------------------------------------------------------------------------------------------------------
if ($mgmtEndpoints) {

    Read-Host "CHECK-POINT: before API Management backend configuration"

    $serviceFabric = New-AzureRmApiManagementBackendServiceFabric -ManagementEndpoint $mgmtEndpoints `
        -ClientCertificateThumbprint $cert.Thumbprint `
        -ServerCertificateThumbprint $serverCertThumbPrints

    $serviceFabric

    $backend = New-AzureRmApiManagementBackend -Context  $ctx `
        -BackendId $ApiMBackendId -Url 'fabric:/Functions' `
        -Protocol http `
        -ServiceFabricCluster $serviceFabric `
        -Title $ApiMBackendTitle `
        -Description $ApiMBackendTitle `
        -Verbose

    $backend

    if ($backend) {
        $prop = Get-AzureRmApiManagementProperty -Context $ctx -Name $ApiMNamedValue
        if ($prop) {
            Set-AzureRmApiManagementProperty -Context $ctx -PropertyId $prop.PropertyId -Value $backend.BackendId
        }
        else {
            New-AzureRmApiManagementProperty -Context $ctx -Name $ApiMNamedValue -Value $backend.BackendId
        }
    }
}


# --------------------------------------------------------------------------------------------------------------
Read-Host "CHECKPOINT: before APIM cleanup"

Get-AzureRmApiManagementBackend -Context $ctx |
    ? {$_.BackendId -match $ApiMBackendIdPrefix -and $_.BackendId -lt $ApiMBackendId} |
    % {Remove-AzureRmApiManagementBackend -Context $ctx -BackendId $_.BackendId}

Get-AzureRmApiManagementCertificate -Context $ctx |
    ? {$_.Subject -eq $certSubject -and $_.CertificateId -lt $certName} | 
    % {Remove-AzureRmApiManagementCertificate -Context $ctx -CertificateId $_.CertificateId}


# --------------------------------------------------------------------------------------------------------------
# !!! ASSUMPTION: Service Fabric clusters hold only 1 client read-only certificate for API Management !!!
Read-Host "CHECKPOINT: before Cluster cleanup"

foreach ($cluster in $clusters) {
    Write-Host " " $cluster.Name "..."
    $cluster.ClientCertificateThumbprints |
        ? {$_.IsAdmin -eq $False -and $_.CertificateThumbprint -ne $cert.Thumbprint} |
        % {Remove-AzureRmServiceFabricClientCertificate -ResourceGroupName $ResourceGroupName -Name $cluster.Name -ReadonlyClientThumbprint $_.CertificateThumbprint}
}

```

Hence policies would refer to the backend using the named value:

```xml
...
<set-backend-service backend-id="{{SFCLUSTER_BACKENDID}}" sf-resolve-condition="@(context.LastError?.Reason == "BackendConnectionFailure")" sf-service-instance-name="fabric:/Functions-MyFunctionApp/webhost" />
<rewrite-uri template="/api/getserviceinfo" copy-unmatched-params="true" />
...
```

> to adapt it to other use cases, the init section of this script can be simplified, the ```$Instance``` can be removed which just reflects the various instances of APIM to SF combinations we have: DEV,...,PROD

## Credits

- thanks to [Matt](https://twitter.com/MattSnider) for helping me out here
