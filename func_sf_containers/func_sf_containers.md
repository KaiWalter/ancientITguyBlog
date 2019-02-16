# Azure Functions inside Containers hosted in Service Fabric

> STARTED: July 2017 | STATUS: work in progress

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

Fortunately containers got supported in SF and I was able to bake [the v1 WebHost into a Windows container](https://github.com/KaiWalter/azure-webjobs-sdk-script-webhost-in-container). Finally with this approach Functions hosted in this pattern could act as first class citizens in the virtual network and we were able to migrated existing stateless Service Fabric applications into these Functions to achieve one common programming model. Also a lot of "jump" APIs (bridging from Functions in public Consumption or App Service Plan into the private virtual network) we hosted in API Management could be removed. 

### Gotchas

#### auto starting IIS

```Dockerfile``` included this configuration to get IIS autostarted and the default web site pointing to the Functions WebHost.

```
RUN Import-Module WebAdministration; \
    Set-ItemProperty 'IIS:\Sites\Default Web Site\' -name physicalPath -value 'C:\WebHost\SiteExtensions\Functions'; \
    Set-ItemProperty 'IIS:\Sites\Default Web Site\' -name serverAutoStart -value 'true'; \
    Set-ItemProperty 'IIS:\AppPools\DefaultAppPool\' -name autoStart -value 'true'
```

#### Always On / Keep Alive

I tested this setup also with background Service Bus queue processing. Though I set the autostart properties for the Web Site, the background processing only started when the WebHost was initiated by a Http trigger. For that reason I keep at least one Http triggered function which I query in the Http health probe of Service Fabrics load balancer. That keeps the WebHost up and running for background processing.

... to be continued ...