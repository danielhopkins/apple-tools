// The once-a-day export with nobody tapping anything.
//
// Two triggers, because neither is guaranteed:
//   HKObserverQuery on step count, with background delivery enabled at
//     `.daily` — Health wakes the app when new steps land, at most daily.
//   BGAppRefreshTask, which iOS schedules when it feels like it.
// Either one runs the 8-day export when the last run is older than 20 h,
// and logs what it did. ⚠️ iOS decides when a background task runs; a
// phone that is locked and idle may run it hours later than asked, and
// the log is where to look before concluding it did not run.

import BackgroundTasks
import Foundation
import HealthKit

enum Background {
    static let taskID = "com.boulderhopkins.apple-tools.health.refresh"
    static let window = 8
    static let minimumGap: TimeInterval = 20 * 3600

    static func register(exporter: Exporter) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            Task { @MainActor in
                let ran = await runIfDue(exporter: exporter, trigger: "app refresh")
                task.setTaskCompleted(success: ran)
                schedule()
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date().addingTimeInterval(minimumGap)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Task { @MainActor in Log.shared.add("could not schedule app refresh: \(error.localizedDescription)", error: true) }
        }
    }

    @MainActor
    static func enableObserver(exporter: Exporter) {
        let type = HKQuantityType(.stepCount)
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            Task { @MainActor in
                if let error = error {
                    Log.shared.add("observer: \(error.localizedDescription)", error: true)
                } else {
                    _ = await runIfDue(exporter: exporter, trigger: "Health update")
                }
                completion()
            }
        }
        exporter.store.execute(query)
        exporter.store.enableBackgroundDelivery(for: type, frequency: .daily) { ok, error in
            Task { @MainActor in
                if ok {
                    Log.shared.add("background delivery on: daily, on new steps")
                } else {
                    Log.shared.add("background delivery refused: \(error?.localizedDescription ?? "?")", error: true)
                }
            }
        }
    }

    @MainActor
    static func runIfDue(exporter: Exporter, trigger: String) async -> Bool {
        if let last = exporter.lastRun, Date().timeIntervalSince(last) < minimumGap {
            Log.shared.add("\(trigger): skipped, last export \(Int(Date().timeIntervalSince(last) / 3600)) h ago")
            return false
        }
        Log.shared.add("\(trigger): exporting")
        await exporter.exportRecent(days: window)
        return true
    }
}
