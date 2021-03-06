# Azure Functions inside Containers hosted in Service Fabric

## Part 2 - Azure Functions / WebHost v2

> STARTED: June 2018 | STATUS: work in progress

In [Azure Functions inside Containers hosted in Service Fabric - Part 1 (WebHost v1)](./part1.md) the why and how to get the now outdated Azure Functions v1 WebHost working inside containers into Service Fabric is explained.

For v2 there was more support for containerizing Azure Functions. There are already [images on Docker Hub](https://hub.docker.com/_/microsoft-azure-functions-base) and [base image samples on GitHub](https://github.com/Azure/azure-functions-docker/blob/master/host/2.0/nanoserver-1803/Dockerfile) for Windows and Linux which provide what I had to figure out in v1 on my own.

But:

- Nanoserver smalldisk images cannot are ... too small
- no PowerShell in the Nanoserver `microsoft/dotnet:2.1-aspnetcore-runtime-nanoserver-1803` base image - which I needed for a the tweaks I implemented in v1
- PowerShell Core did not have the Certificate cmdlets yet. So how can I load my corporate certificates into the image?

## solving the basic problems

### increase Nanoserver smalldisk OS disk

The solution to this problem is described on Stack Overflow:

- [How can I extend OS disks for Windows Server smalldisk based VMSS or Service Fabric clusters?](https://stackoverflow.com/questions/51336867/how-can-i-extend-os-disks-for-windows-server-smalldisk-based-vmss-or-service-fab)
- [How can I attach a data disk to a Windows Server Azure VM and format it directly in the template?](https://stackoverflow.com/questions/51205573/how-can-i-attach-a-data-disk-to-a-windows-server-azure-vm-and-format-it-directly)

### adding PowerShell Core

Take the sample `Dockerfile` mentioned above and implement a multi-stage build which then allows running the `entry.PS1` script in PowerShell Core:

```
# escape=`

# --------------------------------------------------------------------------------
# PowerShell
FROM mcr.microsoft.com/powershell:nanoserver as ps
...
# --------------------------------------------------------------------------------
# Runtime image
FROM microsoft/dotnet:2.2-aspnetcore-runtime-nanoserver-1803

COPY --from=installer-env ["C:\\runtime", "C:\\runtime"]

COPY --from=ps ["C:\\Program Files\\PowerShell", "C:\\PowerShell"]
...
USER ContainerAdministrator
CMD ["C:\\PowerShell\\pwsh.exe","C:\\entry.PS1"]
```

### adding certoc.exe to install certificates

The same approach for the certificate installation: just borrow from another image

```
...
# --------------------------------------------------------------------------------
# Certificate Tool image
FROM microsoft/nanoserver:sac2016 as tool
...
ADD Certificates\\mycompany.org-cert1.cer C:\\certs\\mycompany.org-cert1.cer
ADD Certificates\\mycompany.org-cert2.cer C:\\certs\\mycompany.org-cert2.cer
ADD host_secret.json C:\\runtime\\Secrets\\host.json
ADD entry.PS1 C:\\entry.PS1

USER ContainerAdministrator
RUN icacls "c:\runtime\secrets" /t /grant Users:M
RUN certoc.exe -addstore root C:\\certs\\mycompany.org-cert1.cer
RUN certoc.exe -addstore root C:\\certs\\mycompany.org-cert2.cer
USER ContainerUser
...
```

Significant changes from Windows Server Core 1803 and Nanoserver 1803 base images required also to switch user context for importing certificates.

### handling secrets

As the `Dockerfile` sample above suggests, also directory ACL needed modification so that the host running in user context is able to write into the secrets folder.

[check out Stack Overflow: System.UnauthorizedAccessException : Access to the path 'C:\runtime\Secrets\host.json' is denied in Azure Functions Windows container](https://stackoverflow.com/questions/53683035/system-unauthorizedaccessexception-access-to-the-path-c-runtime-secrets-host)

### MSI

Also the MSI part needed some tweaking after switching to Nanoserver and PowerShell Core. Until `Get-NetRoute` cmdlet is not available in PowerShell Core, this strange string pipelining exercise is required to extract the default gateway.

```PowerShell
Write-Host "adding route for Managed Service Identity"
$gateway = (route print | ? {$_ -like "*0.0.0.0*0.0.0.0*"} | % {$_ -split " "} | ? {$_.trim() -ne "" } | ? {$_ -ne "0.0.0.0" })[0]
$arguments = 'add', '169.254.169.0', 'mask', '255.255.255.0', $gateway
&'route' $arguments

# --------------------------------------------------------------------------------
# test MSI access
$response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net%2F' -Method GET -Headers @{Metadata = "true"} -UseBasicParsing
Write-Host "MSI StatusCode :" $response.StatusCode

# --------------------------------------------------------------------------------
# start Function Host
dotnet.exe C:\runtime\Microsoft.Azure.WebJobs.Script.WebHost.dll
```

----

## adding more functionality

### @Microsoft.KeyVault(SecretUri=...) application settings

[Azure Functions in App Service support the `@Microsoft.KeyVault()` syntax in application settings.](https://azure.microsoft.com/sv-se/blog/simplifying-security-for-serverless-and-web-apps-with-azure-functions-and-app-service/)  To achieve the same with environment variables inside containers this script extension does the transformation:

```PowerShell
...
# --------------------------------------------------------------------------------
# replace Environment Variables holding KeyVault URIs with actual values
$msiEndpoint = 'http://169.254.169.254/metadata/identity/oauth2/token'
$vaultTokenURI = 'https://vault.azure.net&api-version=2018-02-01'
$authenticationResult = Invoke-RestMethod -Method Get -Headers @{Metadata = "true"} -Uri ($msiEndpoint + '?resource=' + $vaultTokenURI)

if ($authenticationResult) {
    $requestHeader = @{Authorization = "Bearer $($authenticationResult.access_token)"}
   
    $regExpr = "^@Microsoft.KeyVault\(SecretUri=(.*)\)$"

    Get-ChildItem "ENV:*" |
        Where-Object {$_.Value -match $regExpr} |
        ForEach-Object {
        Write-Host "fetching secret for" $_.Key
        $kvUri = [Regex]::Match($_.Value, $regExpr).Groups[1].Value
        if (!$kvUri.Contains("?api-version")) {
            $kvUri += "?api-version=2016-10-01"
        }
        $creds = Invoke-RestMethod -Method GET -Uri $kvUri -ContentType 'application/json' -Headers $requestHeader
        if ($creds) {
            Write-Host "setting secret for" $_.Key
            [Environment]::SetEnvironmentVariable($_.Key, $creds.value, "Process")
        }
    }
}

# --------------------------------------------------------------------------------
# start Function Host
dotnet.exe C:\runtime\Microsoft.Azure.WebJobs.Script.WebHost.dll
```

## related

- [using API Management as Service Fabric container locator](./apim_sf_servicelocator.md)
