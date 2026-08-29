import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class GamificationRepository {
    static let shared = GamificationRepository()
    
    private(set) var currentLevel: GamificationLevel = GamificationDefinitions.levels[0]
    private(set) var totalActiveMinutes: Int64 = 0
    private(set) var unlockedAchievements: [String] = []
    
    private(set) var newLevelReveal: GamificationLevel? = nil
    private(set) var newAchievementsReveal: [String] = []
    
    private let defaults: UserDefaults
    
    // Keys
    private let lastSeenLevelKey = "gamification_last_seen_level"
    private let lastSeenAchievementsKey = "gamification_last_seen_achievements"
    private let maintenanceEndWeekKey = "gamification_maintenance_end_week"
    
    private var lastSeenLevel: Int {
        get { defaults.integer(forKey: lastSeenLevelKey) == 0 ? 1 : defaults.integer(forKey: lastSeenLevelKey) }
        set { defaults.set(newValue, forKey: lastSeenLevelKey) }
    }
    
    private var lastSeenAchievements: Set<String> {
        get { Set(defaults.stringArray(forKey: lastSeenAchievementsKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: lastSeenAchievementsKey) }
    }
    
    var maintenanceEndWeek: String? {
        get { defaults.string(forKey: maintenanceEndWeekKey) }
        set { defaults.set(newValue, forKey: maintenanceEndWeekKey) }
    }
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
    func refresh(rides: [Ride]) {
        let level = GamificationEngine.calculateLevel(from: rides)
        let minutes = GamificationEngine.calculateTotalActiveMinutes(from: rides)
        let achievements = GamificationEngine.getUnlockedAchievements(from: rides)
        
        self.currentLevel = level
        self.totalActiveMinutes = minutes
        self.unlockedAchievements = achievements
        
        if level.level > lastSeenLevel {
            self.newLevelReveal = level
        } else {
            self.newLevelReveal = nil
        }
        
        let newAch = achievements.filter { !lastSeenAchievements.contains($0) }
        self.newAchievementsReveal = newAch
    }
    
    func acknowledgeNewLevel(_ level: GamificationLevel) {
        lastSeenLevel = level.level
        newLevelReveal = nil
    }
    
    func acknowledgeAchievements(_ achievements: [String]) {
        guard !achievements.isEmpty else { return }
        lastSeenAchievements = lastSeenAchievements.union(achievements)
        newAchievementsReveal = newAchievementsReveal.filter { !achievements.contains($0) }
    }
    
    func setMaintenanceMode(weeks: Int) {
        // Dummy logic to derive ISO week for simplicity
        let targetWeek = "2026-W42"
        maintenanceEndWeek = targetWeek
    }
    
    func clearMaintenanceMode() {
        maintenanceEndWeek = nil
    }
}
