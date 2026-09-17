// AppleTools Health — the iPhone half of the `health` plugin.
//
// Reads Health, writes text files into this app's iCloud container, shows
// a log of what it did. The Mac plugin reads the files; nothing here talks
// to anything but Health and iCloud Drive.

import SwiftUI

@main
struct AppleToolsHealthApp: App {
    // One exporter for the window and the background task, so `lastRun`
    // is one value. Registration must happen before launching finishes.
    @StateObject private var exporter: Exporter = .shared
    @StateObject private var log = Log.shared

    init() {
        Background.register(exporter: .shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(exporter)
                .environmentObject(log)
                .task {
                    log.add("launched")
                    Background.schedule()
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var exporter: Exporter
    @EnvironmentObject var log: Log
    @AppStorage("background") private var background = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !exporter.available {
                        Label("Health is not available on this device", systemImage: "xmark.octagon")
                    } else if !exporter.authorized {
                        Button {
                            Task { await exporter.authorize() }
                        } label: {
                            Label("Allow reading Health", systemImage: "heart.text.square")
                        }
                        Text("Health asks once. Everything is read-only.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Label("Health access asked", systemImage: "checkmark.circle")
                    }
                } header: {
                    Text("Access")
                } footer: {
                    Text("Health does not say which types were allowed; a type that was refused simply produces no rows. The log below counts the rows.")
                }

                Section("Export") {
                    Button {
                        Task { await exporter.exportRecent(days: Background.window) }
                    } label: {
                        Label("Export the last \(Background.window) days", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exporter.running)
                    Button {
                        Task { await exporter.exportAll() }
                    } label: {
                        Label("Export everything, one file per year", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(exporter.running)
                    if exporter.running {
                        HStack { ProgressView(); Text("Reading Health…").foregroundStyle(.secondary) }
                    }
                    if let last = exporter.lastRun {
                        LabeledContent("Last export", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let report = exporter.lastReport {
                        LabeledContent("Rows", value: "\(report.days) days · \(report.sleepSamples) sleep · \(report.workouts) workouts · \(report.raw) raw · \(report.clinical) clinical")
                    }
                }

                Section {
                    Toggle(isOn: $background) {
                        Label("Export daily in the background", systemImage: "moon.zzz")
                    }
                    .onChange(of: background) { _, on in
                        if on {
                            Background.enableObserver(exporter: exporter)
                            Background.schedule()
                        } else {
                            exporter.store.disableAllBackgroundDelivery { _, _ in }
                            log.add("background delivery off")
                        }
                    }
                } footer: {
                    Text("Runs the 8-day export when Health reports new steps and the last export is over 20 hours old. iOS decides the exact moment.")
                }

                Section {
                    if let dir = Store.container() {
                        Text(dir.path.replacingOccurrences(of: "/private/var/mobile/Library/Mobile Documents/", with: "iCloud Drive/"))
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    } else {
                        Label("No iCloud container. Turn on iCloud Drive for this app in Settings.", systemImage: "icloud.slash")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Files go to")
                } footer: {
                    Text("On the Mac: ~/Library/Mobile Documents/iCloud~com~boulderhopkins~apple-tools~health/Documents/health, which `apple health sync` reads.")
                }

                Section {
                    ForEach(log.lines.reversed()) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.text)
                                .foregroundStyle(line.error ? .red : .primary)
                            Text(line.when.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Log")
                        Spacer()
                        Button("Clear") { log.clear() }.font(.caption)
                    }
                }
            }
            .navigationTitle("AppleTools Health")
        }
    }
}
