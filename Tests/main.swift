import Foundation

let now = Date()
let plus = CodexFastLimitStatus(
    usedPercent: 25,
    secondaryUsedPercent: 40,
    resetsAt: now.addingTimeInterval(3_600),
    secondaryResetsAt: now.addingTimeInterval(86_400),
    primaryWindowMinutes: 300,
    secondaryWindowMinutes: 10_080,
    eventDate: now,
    isMainCodexLimit: true,
    isAuthoritative: true
)
precondition(plus.window(minutes: 300)?.usedPercent == 25)
precondition(plus.window(minutes: 10_080)?.usedPercent == 40)
precondition(
    resolvedMenuBarLimitDisplay(
        preferred: .fiveHour,
        weeklyAvailable: true,
        fiveHourAvailable: true
    ) == .fiveHour
)

let pro20x = CodexFastLimitStatus(
    usedPercent: 55,
    secondaryUsedPercent: nil,
    resetsAt: now.addingTimeInterval(86_400),
    secondaryResetsAt: nil,
    primaryWindowMinutes: 10_080,
    secondaryWindowMinutes: nil,
    eventDate: now,
    isMainCodexLimit: true,
    isAuthoritative: true
)
precondition(pro20x.window(minutes: 300) == nil)
precondition(pro20x.window(minutes: 10_080)?.usedPercent == 55)
precondition(
    resolvedMenuBarLimitDisplay(
        preferred: .fiveHour,
        weeklyAvailable: true,
        fiveHourAvailable: false
    ) == .weekly
)

let currentPackagedCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
if FileManager.default.isExecutableFile(atPath: currentPackagedCodex) {
    precondition(
        CodexRPCUsageReader.codexExecutableURL()?.path == currentPackagedCodex,
        "Current ChatGPT-packaged Codex CLI should be discovered"
    )
}

print("Plus / Pro rate-limit compatibility checks passed")
