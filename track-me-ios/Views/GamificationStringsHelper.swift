import Foundation

public enum GamificationStringsHelper {
    public static func levelName(for levelId: String) -> String {
        switch levelId {
        case "level_1": return LocalizationHelper.localized("Starter")
        case "level_2": return LocalizationHelper.localized("Moving")
        case "level_3": return LocalizationHelper.localized("Regular")
        case "level_4": return LocalizationHelper.localized("Explorer")
        case "level_5": return LocalizationHelper.localized("Enduring")
        case "level_6": return LocalizationHelper.localized("Pathfinder")
        default: return LocalizationHelper.localized("Starter")
        }
    }
    
    public static func milestoneTitle(for milestoneId: String) -> String {
        let countString = milestoneId.replacingOccurrences(of: "milestone_", with: "")
        guard let count = Int(countString) else { return milestoneId }
        
        if count == 1 {
            return LocalizationHelper.localized("First Qualifying Activity")
        } else {
            return LocalizationHelper.formatted("%d rides", count)
        }
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
}
