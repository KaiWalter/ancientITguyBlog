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

To exchange connection and certificate while in operation, I chose to always create a new certificate (suffixed with a timestamp) and a new backend entity (as well suffixed), wire them up, put the new backend id into an API Management Named Value to be used by policies and then afterwards removing the obsolete certificates and backend objects: [configureApiManagement2Cluster.ps1](./configureApiManagement2Cluster.PS1)

> to adapt it to other use cases, the init section of this script can be simplified, the ```$Instance``` can be removed which just reflects the various instances of APIM to SF combinations we have: DEV,...,PROD

## Credits

- thanks to [Matt](https://twitter.com/MattSnider) for helping me out here
