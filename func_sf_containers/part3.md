# Azure Functions inside Containers hosted in Service Fabric

## Part 3 - Solve the singleton mystery

While incrementally migrating Function Apps from v1 to v2 I realized, that all of a sudden the singleton execution of a timer triggered function did not work anymore with v2. In v1 you could just put the host id common for all instances of the same function app executed across multiple containers into `host.json`:

```json
{
  "id": "4c45009422854e56a8a70567cd7219fe",
...
```

WebHost instances then lock or synchronizes singleton executions over the shared storage (referenced by `AzureWebJobsStorage`).

The function - migrated to v2 - suddenly executed multiple times (in exactly the number of containers of the same function app) at the same interval which was definitely not the intended behavior. `id` specified in `host.json` did not seem to be relevant anymore.

Checking `ScriptHostIdProvider` in the v2 host I learned, that `id` can be set in an environment variable:

```bash
...
AzureFunctionsWebHost:hostid=4c45009422854e56a8a70567cd7219fe
...
```

Usually the platform (Azure Functions / App Service) cares about setting this unique id. But when hosting the Functions runtime in multiple instances one has to take care of this.  

Still the makers of the Functions runtime are not favor setting an explicit `hostid`

- https://github.com/Azure/Azure-Functions/issues/809
- https://github.com/Azure/azure-functions-core-tools/issues/1012

and for that issue a warning when the host starts up:

```log
warn: Host.Startup[0]
      Host id explicitly set in configuration. This is not a recommended configuration and may lead to unexpected behavior.
info: Host.Startup[0]
      Starting Host (HostId=4c45009422854e56a8a70567cd7219fe, InstanceId=181fb9ee-be21-4c7e-bcf1-c325fce7532b, Version=2.0.12353.0, ProcessId=5804, AppDomainId=1, InDebugMode=False, InDiagnosticMode=False, FunctionsExtensionVersion=)
```

> Important: when sharing the same storage (referenced by `AzureWebJobsStorage`) among multiple function apps, the `hostid` has to be unique for each function app. Otherwise domestic function app locking and durable functions can get messed up.