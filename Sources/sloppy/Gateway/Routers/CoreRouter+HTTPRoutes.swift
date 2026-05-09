import Foundation

extension CoreRouter {
    static func defaultRoutes(service: CoreService) -> [RouteDefinition] {
        let router = CoreRouterRegistrar()
        var routers: [APIRouter] = [
            SystemAPIRouter(service: service),
            ChannelsAPIRouter(service: service),
            SessionsAPIRouter(service: service),
            ProjectsAPIRouter(service: service),
            TasksAPIRouter(service: service),
            ProvidersAPIRouter(service: service),
            GitHubAPIRouter(service: service),
            TaskSyncAPIRouter(service: service),
            ACPAPIRouter(service: service),
            AgentsAPIRouter(service: service),
            ActorsAPIRouter(service: service),
            CronAPIRouter(service: service),
            SkillsAPIRouter(service: service),
            ArtifactsAPIRouter(service: service),
            PluginsAPIRouter(service: service)
        ]

        if !SloppyVersion.isReleaseBuild {
            routers.append(DebugAPIRouter(service: service))
        }

        for apiRouter in routers {
            apiRouter.configure(on: router)
        }

        return router.routes
    }
}
