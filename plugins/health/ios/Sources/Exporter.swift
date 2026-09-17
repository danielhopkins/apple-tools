// Reads Health and writes the files the Mac plugin reads.
//
// Three queries do all of it:
//   HKStatisticsCollectionQuery, one per metric, day interval anchored at
//     local midnight. 🛑 THIS IS WHAT GIVES HEALTH'S OWN DAILY TOTALS: it
//     merges the iPhone's and the Watch's overlapping samples the way the
//     Health app does. Summing raw samples counts a walk twice.
//   HKSampleQuery for sleep analysis: raw stage samples, because a night
//     belongs to the morning and the plugin files it there.
//   HKSampleQuery for workouts, plus one HKWorkoutRouteQuery per workout
//     with a route, read only far enough to get the first location.

import CoreLocation
import Foundation
import HealthKit

struct ExportReport {
    var days = 0
    var sleepSamples = 0
    var workouts = 0
    var files: [String] = []
}

@MainActor
final class Exporter: ObservableObject {
    @Published var authorized = false
    @Published var running = false
    @Published var lastReport: ExportReport?
    @Published var lastRun: Date? = UserDefaults.standard.object(forKey: "lastRun") as? Date

    let store = HKHealthStore()
    private let log = Log.shared

    static let shared = Exporter()

    static let readTypes: Set<HKObjectType> = {
        var set = Set<HKObjectType>()
        for m in Metric.all { set.insert(HKQuantityType(m.type)) }
        set.insert(HKCategoryType(.sleepAnalysis))
        set.insert(HKWorkoutType.workoutType())
        set.insert(HKSeriesType.workoutRoute())
        set.insert(HKQuantityType(.heartRate))
        return set
    }()

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    func authorize() async {
        guard available else {
            log.add("Health is not available on this device", error: true)
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: Exporter.readTypes)
            authorized = true
            log.add("asked Health for read access to \(Exporter.readTypes.count) types")
        } catch {
            log.add("authorization failed: \(error.localizedDescription)", error: true)
        }
    }

    /// The last `days` days, into one file named for today.
    func exportRecent(days: Int) async {
        let end = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end)!
        await run(name: "last \(days) days", from: start, to: end, window: days, fileName: "health-\(Format.days.string(from: Date())).txt")
    }

    /// Everything Health holds, one file per year, oldest first.
    func exportAll() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let earliest = await earliestDate() ?? Calendar.current.date(byAdding: .year, value: -5, to: Date())!
        let firstYear = Calendar.current.component(.year, from: earliest)
        let thisYear = Calendar.current.component(.year, from: Date())
        log.add("full export: \(firstYear) to \(thisYear), earliest sample \(Format.days.string(from: earliest))")
        var total = ExportReport()
        for year in firstYear...thisYear {
            let start = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1))!
            let end = Calendar.current.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
            if let report = await export(from: start, to: min(end, Date().addingTimeInterval(86400)),
                                         window: 366, fileName: "health-\(year).txt") {
                total.days += report.days
                total.sleepSamples += report.sleepSamples
                total.workouts += report.workouts
                total.files += report.files
            }
        }
        lastReport = total
        log.add("full export done: \(total.days) day rows, \(total.sleepSamples) sleep samples, \(total.workouts) workouts, \(total.files.count) files")
        markRun()
    }

    private func run(name: String, from start: Date, to end: Date, window: Int, fileName: String) async {
        guard !running else { return }
        running = true
        defer { running = false }
        log.add("export \(name): \(Format.days.string(from: start)) to \(Format.days.string(from: end))")
        if let report = await export(from: start, to: end, window: window, fileName: fileName) {
            lastReport = report
            log.add("wrote \(fileName): \(report.days) day rows, \(report.sleepSamples) sleep samples, \(report.workouts) workouts")
            markRun()
        }
    }

    private func markRun() {
        lastRun = Date()
        UserDefaults.standard.set(lastRun, forKey: "lastRun")
    }

    /// One file. Returns nil, after logging, when nothing could be written.
    private func export(from start: Date, to end: Date, window: Int, fileName: String) async -> ExportReport? {
        guard let dir = Store.container() else {
            log.add("no iCloud container: is iCloud Drive on for this app?", error: true)
            return nil
        }
        var text = Format.header(window: window)
        var report = ExportReport()

        for metric in Metric.all {
            do {
                let rows = try await dailyTotals(metric, from: start, to: end)
                for (dayStart, dayEnd, value) in rows {
                    text += Format.day(label: metric.label, start: dayStart, end: dayEnd, value: value, unit: metric.unitText)
                }
                report.days += rows.count
            } catch {
                log.add("\(metric.label): \(error.localizedDescription)", error: true)
            }
        }

        do {
            let samples = try await sleepSamples(from: start, to: end)
            for s in samples {
                if let stage = sleepStage(s.value) {
                    text += Format.sample(label: "Sleep", start: s.startDate, end: s.endDate, value: stage, unit: "count")
                    report.sleepSamples += 1
                }
            }
        } catch {
            log.add("Sleep: \(error.localizedDescription)", error: true)
        }

        do {
            let workouts = try await workouts(from: start, to: end)
            for w in workouts {
                let point = await firstRoutePoint(of: w)
                text += Format.workout(
                    type: workoutLabel(w.workoutActivityType), start: w.startDate, end: w.endDate,
                    seconds: w.duration,
                    metres: distance(of: w), kcal: energy(of: w), bpm: heartRate(of: w),
                    source: w.sourceRevision.source.name,
                    lat: point?.coordinate.latitude, lon: point?.coordinate.longitude)
                report.workouts += 1
            }
        } catch {
            log.add("Workouts: \(error.localizedDescription)", error: true)
        }

        let url = dir.appendingPathComponent(fileName)
        do {
            try text.data(using: .utf8)!.write(to: url, options: .atomic)
            report.files.append(fileName)
        } catch {
            log.add("could not write \(fileName): \(error.localizedDescription)", error: true)
            return nil
        }
        return report
    }

    // MARK: queries

    private func dailyTotals(_ metric: Metric, from start: Date, to end: Date) async throws -> [(Date, Date, Double)] {
        let type = HKQuantityType(metric.type)
        let options: HKStatisticsOptions
        switch metric.rule {
        case .sum: options = .cumulativeSum
        case .mean: options = .discreteAverage
        case .last: options = .mostRecent
        }
        let anchor = Calendar.current.startOfDay(for: start)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await withCheckedThrowingContinuation { cont in
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                    options: options, anchorDate: anchor,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error = error { cont.resume(throwing: error); return }
                var rows: [(Date, Date, Double)] = []
                collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                    let quantity: HKQuantity?
                    switch metric.rule {
                    case .sum: quantity = stats.sumQuantity()
                    case .mean: quantity = stats.averageQuantity()
                    case .last: quantity = stats.mostRecentQuantity()
                    }
                    if let q = quantity {
                        rows.append((stats.startDate, stats.endDate, q.doubleValue(for: metric.unit)))
                    }
                }
                cont.resume(returning: rows)
            }
            store.execute(query)
        }
    }

    private func sleepSamples(from start: Date, to end: Date) async throws -> [HKCategorySample] {
        let type = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
    }

    private func workouts(from start: Date, to end: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await withCheckedThrowingContinuation { cont in
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                if let error = error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
    }

    /// The earliest step sample, which is as far back as the history goes.
    private func earliestDate() async -> Date? {
        await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: HKQuantityType(.stepCount), predicate: nil, limit: 1,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, _ in
                cont.resume(returning: samples?.first?.startDate)
            }
            store.execute(query)
        }
    }

    /// The first location of the workout's route, or nil when it has none.
    /// ⚠️ A route streams in batches; the query is stopped after the first
    /// batch delivers a point, because one point is all the plugin uses.
    private func firstRoutePoint(of workout: HKWorkout) async -> CLLocation? {
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { cont in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate, limit: 1,
                                      sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(query)
        }
        guard let route = routes.first else { return nil }
        return await withCheckedContinuation { cont in
            var done = false
            let query = HKWorkoutRouteQuery(route: route) { query, locations, finished, _ in
                if done { return }
                if let first = locations?.first {
                    done = true
                    cont.resume(returning: first)
                    self.store.stop(query)
                } else if finished {
                    done = true
                    cont.resume(returning: nil)
                }
            }
            store.execute(query)
        }
    }

    // MARK: workout fields

    private func distance(of w: HKWorkout) -> Double? {
        for id in [HKQuantityTypeIdentifier.distanceCycling, .distanceWalkingRunning, .distanceSwimming,
                   .distanceDownhillSnowSports, .distanceWheelchair] {
            if let q = w.statistics(for: HKQuantityType(id))?.sumQuantity() {
                return q.doubleValue(for: .meter())
            }
        }
        return nil
    }

    private func energy(of w: HKWorkout) -> Double? {
        w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
    }

    private func heartRate(of w: HKWorkout) -> Double? {
        w.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?
            .doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
    }
}
