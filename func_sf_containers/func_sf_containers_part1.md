# Azure Functions inside Containers hosted in Service Fabric

## Part 1 - Azure Functions / WebHost v1

## Why ?

I'm working on a project which is a platform for integrating applications that exist outside our corporate network to our corporate back-end systems. A good share of this [integration platform](https://www.youtube.com/watch?v=BoZimCedfq8&feature=youtu.be&t=1328) is build in the Microsoft Azure cloud environment.

Though it is "only" intended as an integration layer between digital and classical world, it still keeps some business data and logic worth protecting and not having out in the "open".

Most of the services we use in this scenario - _API Management, Cosmos DB, Service Bus, Service Fabric, Storage_ - are available with virtual network endpoints and thus access to these services can be limited to the boundaries of the virtual network - also limiting the attack surface of the overall environment.

One major element of the integration story is the processing logic. This is implemented using the simple stateless input-processing-output notion which **Azure Functions** (and other function & serverless platforms) deliver. In fact the transformations happening in these functions are the very DNA of the system while the other services "just" as much as fulfill their single intended purpose (storing, queueing, ...).

### The challenge

Now. How to get these functions also inside the boundaries of the virtual network ...

- with seamless access to connected back-end resources
- without any public exposure

**App Service** capability of **VNET** peering was not sufficient enough for me to fulfull these requirements.

App Service Environment (aka **ASE**): back in summer 2017 instance deployment times here in West Europe of ~4-6h and also the cost were beyond reasonable justification. Additionally ASE spinned up a lot of VMs / resources which would not be properly untilized in a Functions only scenario. May be meanwhile it has improved with v2 - I did not check.

We already had **Service Fabric** running inside the virtual network -  covering the few stateful services of the platform. So why not just squeeze Azure Functions somehow into Service Fabric?

## Motivation

Bits and pieces, I figured out along the journey, I already put in several Q&A style articles on Stackoverflow. However I wanted to piece it together into a more comprehensive story to give people out there a chance to follow along and may be adapt a few things for themselves.

## WebHost v1 as Service Fabric application

I invested some time into this before containers were available on Service Fabric. Forking the WebJobs Scripts SDK / Functions v1 I tried to adapt the code so that it can run as a native Service Fabric application. Too much work. Lacking knowledge on my end to succeed.

I managed to get  a [Functions console host as Guest executable hosted in Service Fabric](https://github.com/KaiWalter/azure-webjobs-sdk-script-console-host-in-servicefabric) but that did not help I really needed the WebHost.

## WebHost v1 as container in Service Fabric

Fortunately around fall 2017 containers got supported in SF and I was able to bake [the v1 WebHost into a Windows container](https://github.com/KaiWalter/azure-webjobs-sdk-script-webhost-in-container).

Finally with this approach Functions hosted in this pattern could exist as first class citizens in the virtual network and we were able to migrated existing stateless Service Fabric applications into these Functions to achieve one common programming model. Also a lot of "jump" APIs (bridging from Functions in public Consumption or App Service Plan into the private virtual network) we hosted in API Management could be removed.

----

### key elements and gotchas

#### building the Function host

When I started it was possible to download the pre-built Functions host directly with the ```Dockerfile```:

```
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ADD https://github.com/Azure/azure-functions-host/releases/download/1.0.11559/Functions.Private.1.0.11559.zip C:\\WebHost.zip

RUN Expand-Archive C:\WebHost.zip ; Remove-Item WebHost.zip`
```

At some point the team stopped providing these precanned versions. This required to adjust our CI/CD process for the Functions host base image into [part 1 / downloading the source code](./DownloadSource.PS1), part 2 / building it e.g. in Azure DevOps aka VSTS to be part 3 / loaded into the base image.

```
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ADD Functions.Private.zip C:\\WebHost.zip

RUN Expand-Archive C:\WebHost.zip ; Remove-Item WebHost.zip
```

#### managing master key / secrets

To control the master key the Function host uses on startup - instead of generating ramdom keys - can be achieved by creating a ```host_secrets.json``` file

```
{
   "masterKey": {
   "name": "master",
   "value": "asGmO6TCW/t42krL9CljNod3uG9aji4mJsQ7==",
   "encrypted": false
},
"functionKeys": [
      {
         "name": "default",
         "value": "asGmO6TCW/t42krL9CljNod3uG9aji4mJsQ7==",
         "encrypted": false
      }
   ]
}
```

and then copy this file into the designated secrets folder of the Function host (```Dockerfile```):

```
ADD host_secrets.json C:\\WebHost\\SiteExtensions\\Functions\\App_Data\\Secrets\\host.json
```

#### auto starting web site

```Dockerfile``` included this configuration to get IIS autostarted and the default web site pointing to the Functions WebHost.

```PowerShell
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

RUN Import-Module WebAdministration; \
    Set-ItemProperty 'IIS:\Sites\Default Web Site\' -name physicalPath -value 'C:\WebHost\SiteExtensions\Functions'; \
    Set-ItemProperty 'IIS:\Sites\Default Web Site\' -name serverAutoStart -value 'true'; \
    Set-ItemProperty 'IIS:\AppPools\DefaultAppPool\' -name autoStart -value 'true'
```

#### Always On / Keep Alive

I tested this setup also with background Service Bus queue processing. Though I set the autostart properties for the Web Site, the background processing only started when the WebHost was initiated by a Http trigger. For that reason I keep at least one Http triggered function (e.g. ```GetServiceInfo```) which I query in the HTTP health probe of Service Fabrics load balancer. That keeps the WebHost up and running for background processing.

```
...
        "loadBalancingRules": [
          {
            "name": "Service28000LBRule",
            "properties": {
              "backendAddressPool": {
                "id": "[variables('lbPoolID0')]"
              },
              "backendPort": 28000,
              "enableFloatingIP": false,
              "frontendIPConfiguration": {
                "id": "[variables('lbIPConfig0')]"
              },
              "frontendPort": 28000,
              "idleTimeoutInMinutes": 5,
              "probe": {
                "id": "[concat(variables('lbID0'),'/probes/Service28000Probe')]"
              },
              "protocol": "Tcp"
            }
          },
...
        "probes": [{
...
          {
            "name": "Service28000Probe",
            "properties": {
              "protocol": "Http",
              "port": 28000,
              "requestPath": "/api/GetServiceInfo",
              "intervalInSeconds": 60,
              "numberOfProbes": 2
            }
          },
...
```

#### loading own set of certificates

```Dockerfile``` can be used to load certificates into the container, to be used by the Function App:

```PowerShell
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ADD Certificates\\mycompany.org-cert1.cer C:\\certs\\mycompany.org-cert1.cer
ADD Certificates\\mycompany.org-cert2.cer C:\\certs\\mycompany.org-cert2.cer

RUN Set-Location -Path cert:\LocalMachine\Root;\
    Import-Certificate -Filepath "C:\\certs\\mycompany.org-cert1.cer";\
    Import-Certificate -Filepath "C:\\certs\\mycompany.org-cert2.cer";\
	Get-ChildItem;
```

#### the whole nine yards

This is what a base image ```Dockerfile``` may look like

```
FROM microsoft/aspnet:4.7.1
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

ADD Functions.Private.zip C:\\WebHost.zip

RUN Expand-Archive C:\WebHost.zip ; Remove-Item WebHost.zip

ADD host_secrets.json C:\\WebHost\\SiteExtensions\\Functions\\App_Data\\Secrets\\host.json

ADD entry.PS1 C:\\entry.PS1

ADD Certificates\\mycompany.org-cert1.cer C:\\certs\\mycompany.org-cert1.cer
ADD Certificates\\mycompany.org-cert2.cer C:\\certs\\mycompany.org-cert2.cer

RUN Set-Location -Path cert:\LocalMachine\Root;\
    Import-Certificate -Filepath "C:\\certs\\mycompany.org-cert1.cer";\
    Import-Certificate -Filepath "C:\\certs\\mycompany.org-cert2.cer";\
	Get-ChildItem;

RUN Import-Module WebAdministration;                                                        \
    $websitePath = 'C:\WebHost\SiteExtensions\Functions';                                   \
    Set-ItemProperty 'IIS:\Sites\Default Web Site\' -name physicalPath -value $websitePath; \
    Set-ItemProperty 'IIS:\Sites\Default Web Site\' -name serverAutoStart -value 'true';    \
    Set-ItemProperty 'IIS:\AppPools\DefaultAppPool\' -name autoStart -value 'true';

EXPOSE 80
```

which can be referenced by App specific ```Dockerfile``` like:

```
FROM mycompanycr.azurecr.io/functions.webhost:1.0.11612
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

COPY App.zip App.zip

RUN Expand-Archive App.zip ; \
    Remove-Item App.zip

SHELL ["cmd", "/S", "/C"]
ENV AzureWebJobsScriptRoot='C:\App'

WORKDIR App
```

Each Azure Function host release is loaded into the container registry with a corresponding release tags. This allowed for operating Function apps with different (proven or preliminary) versions of the Function host.


#### extending the startup

To add more processing to the app containers startup (which we will need later) the ```ENTRYPOINT``` passed down from the ```microsoft/aspnet:4.7.x``` image

```
...
ENTRYPOINT ["C:\\ServiceMonitor.exe", "w3svc"]
```

can be replaced with an alternate entry script

```
...
    Set-ItemProperty 'IIS:\AppPools\DefaultAppPool\' -name autoStart -value 'true';

EXPOSE 80

ENTRYPOINT ["powershell.exe","C:\\entry.PS1"]
```

which executes steps at start of the container:

```
...
# this is where the magic happens
...
C:\ServiceMonitor.exe w3svc
```

### MSI = managed service identity

Functions operated in App Service allow managed service identity to access secrets from KeyVault.

To achieve the same in our environment we first had to [add managed service identity to Service Fabrics / VM scalesets](https://stackoverflow.com/questions/52578135/how-can-i-add-managed-service-identity-to-a-container-hosted-inside-azure-vm-sca/52578136#52578136).

Now ```entry.PS1``` startup script introduced above can be used to add the route to the MSI endpoint and check it on container startup:

```PowerShell
Write-Host "adding route for Managed Service Identity"
$gateway = (Get-NetRoute | Where-Object {$_.DestinationPrefix -eq '0.0.0.0/0'}).NextHop
$arguments = 'add','169.254.169.0','mask','255.255.255.0',$gateway
&'route' $arguments

$response = Invoke-WebRequest -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net%2F' -Method GET -Headers @{Metadata="true"} -UseBasicParsing
Write-Host "MSI StatusCode :" $response.StatusCode

C:\ServiceMonitor.exe w3svc
```

----

## to be continued ...

OK, problem solved.

But:

- Windows Server Core images have ~6GB size - hence Service Fabric nodes need an awful amount of time to load new versions of these
- time goes on, MSI is around the corner

With Azure Functions v2 and .NET Core it is possible to have images reduced in size and host those on Linux: [Azure Functions inside Containers hosted in Service Fabric - Part 2 (WebHost v2)](./func_sf_containers_part2.md)