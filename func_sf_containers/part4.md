# Azure Functions inside Containers hosted in Service Fabric

## ServiceBus NamespaceManager over MSI

As NamespaceManager is not supported anymore with the .NET Core compatible package `Microsoft.Azure.ServiceBus` (which is a dependency of `Microsoft.Azure.WebJobs.Extensions.ServiceBus` when using Service Bus within WebJobs or Functions)), the package `Microsoft.Azure.Management.ServiceBus.Fluent` and affiliates have to be used.

This package supports a MSI based authentication and I can leverage the availability of [MSI - which I described here for v2 WebHosts](./part2.md):

```cs
...
    // some magic that determines subscriptionId, resourceGroupName & sbNamespaceName
...
    var credentials = SdkContext.AzureCredentialsFactory.FromMSI(new MSILoginInformation(MSIResourceType.VirtualMachine), AzureEnvironment.AzureGlobalCloud);
    var azure = Azure
            .Configure()
            .WithLogLevel(HttpLoggingDelegatingHandler.Level.Basic)
            .Authenticate(credentials)
            .WithSubscription(subscriptionId);

    var sbNamespace = azure.ServiceBusNamespaces.GetByResourceGroup(resourceGroupName, sbNamespaceName);
    var queues = sbNamespace.Queues.List();
...
```

The only thing left is to authorize the MSI created in the AAD for the clusters VM Scale Set on the Service Bus resource - e.g. granting a _Reader_ role when as in my case only queue message count need to be retrieved.