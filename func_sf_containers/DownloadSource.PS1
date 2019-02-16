param(
    [string]$DownloadBuildNumber
)

$url = "https://github.com/Azure/azure-functions-host/archive/" + $DownloadBuildNumber + ".zip"
$url2 = "https://github.com/Azure/azure-functions-host/archive/v" + $DownloadBuildNumber + ".zip"


$targetZip = Join-Path $PSScriptRoot "WebHost.zip"
if (Test-Path $targetZip) {
    Remove-Item $targetZip -Force
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    Write-Host "Downloading" $url
    (New-Object Net.WebClient).DownloadFile($url, $targetZip)
}
catch {
    Write-Host "not found on URL" $url
}
if (!(Test-Path $targetZip)) {
    try {
        Write-Host "Downloading" $url2
        (New-Object Net.WebClient).DownloadFile($url2, $targetZip)
    }
    catch {
        Write-Host "not found on URL" $url2
    }
}
if (Test-Path $targetZip) {

    Expand-Archive $targetZip
    Remove-Item $targetZip
        
    $sources = (Get-ChildItem azure-functions-host* -Recurse -Directory)[0]
        
    Move-Item $sources Sources
        
}
else {
    Write-Host "##vso[task.logissue type=error;] URL error"
}
