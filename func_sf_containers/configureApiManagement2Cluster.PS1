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
