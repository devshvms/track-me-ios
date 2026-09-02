import Foundation

public enum GamificationStringsHelper {
    public static func levelName(forNameKey nameKey: String) -> String {
        LocalizationHelper.localized(nameKey)
    }
    
    public static func milestoneTitle(activityCount count: Int) -> String {
        if count == 1 {
            return LocalizationHelper.localized("First Qualifying Activity")
        }
        return LocalizationHelper.formatted("%@ qualifying activities", String(count))
    }

    public static func activeMinutes(_ minutes: Int64) -> String {
        LocalizationHelper.formatted("%@ active minutes", String(minutes))
    }

    public static func nextLevelProgress(current: Int64, next: Int64) -> String {
        LocalizationHelper.formatted(
            "%@ active minutes • next level at %@",
            String(current),
            String(next)
        )
    }

    public static func maximumLevel(current: Int64) -> String {
        LocalizationHelper.formatted("Maximum level • %@ active minutes", String(current))
    }

    public static func unlockCriterion(minutes: Int64) -> String {
        LocalizationHelper.formatted("Unlocks at %@ active minutes", String(minutes))
    }
    
    public static var myProgress: String {
        LocalizationHelper.localized("My Progress")
    }
    
    public static var viewProgress: String {
        LocalizationHelper.localized("View progress")
    }
    
    public static var levels: String {
        LocalizationHelper.localized("Levels")
    }
    
    public static var milestones: String {
        LocalizationHelper.localized("Milestones")
    }
    
    public static var unlocked: String {
        LocalizationHelper.localized("Unlocked")
    }
    
    public static var locked: String {
        LocalizationHelper.localized("Locked")
    }

    public static var latestMilestone: String {
        LocalizationHelper.localized("Latest milestone")
    }
}
