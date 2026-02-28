import { createCoreApi, type CoreApi } from "../../shared/api/coreApi";

export interface DashboardDependencies {
  coreApi: CoreApi;
}

export function createDependencies(): DashboardDependencies {
  return {
    coreApi: createCoreApi()
  };
}
