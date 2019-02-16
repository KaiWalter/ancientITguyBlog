# Azure Functions inside Containers hosted in Service Fabric

> STARTED: August 2017 | STATUS: work in progress

## Why ?

I'm working on a project which is a platform for integrating applications that exist outside our corporate network to our corporate back-end systems. A good share of this [integration platform](https://www.youtube.com/watch?v=BoZimCedfq8&feature=youtu.be&t=1328) is build in the Microsoft Azure cloud environment.

Though it is "only" intended as an integration layer between digital and classical world, it still keeps some business data and logic worth protecting and not having out in the "open".

Most of the services we use - _API Management, Cosmos DB, Service Bus, Service Fabric, Storage_ - are available with virtual network endpoints and thus access to these services can be limited to the boundaries of the virtual network - also limiting the attack surface of the overall environment.

One major element of the integration story is the processing logic. This is implemented using the simple stateless input-processing-output notion which Azure Functions (and other function & serverless platforms) deliver. In fact the transformations happening in these functions are the very DNA of the system while the other services "just" as much as fulfill their single intended purpose (storing, queueing, ...).

### The challenge

Now. How to get these functions also inside the boundaries of the virtual network ...

- with seamless access to connected back-end resources
- without any public exposure 

App Service capability of VNET peering was not sufficient enough for me to fulfull these requirements.

App Service Environment (aka ASE): back in summer 2017 instance deployment times here in West Europe of ~4-6h and also the cost were just not bearable. May be meanwhile it has improved with v2 - I did not check.

We already had Service Fabric running inside the virtual network -  covering the few stateful services of the platform. Why not just squeeze Azure Functions somehow into Service Fabric?

... to be continued ...