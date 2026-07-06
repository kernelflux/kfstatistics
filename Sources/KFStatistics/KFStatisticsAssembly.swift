import KFService
import KFStatisticsCore

public struct KFStatisticsAssembly: ServiceAssembly {
    public init() {}
    public func assemble(container: ServiceContainer) {
        KFStatistics.preload()
        container.register(KFStatisticsService.self) { KFStatisticsDefault() }
    }
}
