import SwiftUI
import Charts

struct InsightsView: View {
    @EnvironmentObject var store: InsightsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Insights").font(.title2.bold())
                    Text("What dictating instead of typing is getting you.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    StatCard(title: "Today", value: "\(store.todayWords)", unit: "words")
                    StatCard(title: "Last 7 days", value: "\(store.weekWords)", unit: "words")
                    StatCard(title: "All time", value: store.totalWords.formatted(), unit: "words")
                    StatCard(title: "Time saved", value: timeSavedText, unit: "vs typing 40 WPM")
                    StatCard(title: "Streak", value: "\(store.streakDays)", unit: store.streakDays == 1 ? "day" : "days")
                    StatCard(title: "Dictations", value: "\(store.events.count)", unit: "total")
                }

                GroupBox("Words per day — last 14 days") {
                    Chart(store.last14Days()) { day in
                        BarMark(
                            x: .value("Day", day.label),
                            y: .value("Words", day.words)
                        )
                        .cornerRadius(3)
                    }
                    .frame(height: 160)
                    .padding(.top, 6)
                }

                GroupBox("Top apps") {
                    let apps = store.topApps()
                    if apps.isEmpty {
                        Text("No dictations yet — hold your hotkey and talk.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else {
                        VStack(spacing: 6) {
                            ForEach(apps, id: \.app) { item in
                                HStack {
                                    Text(item.app)
                                    Spacer()
                                    Text("\(item.words) words").foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        .padding(8)
                    }
                }

                GroupBox("Recent") {
                    let recent = store.events.suffix(15).reversed()
                    if recent.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding()
                    } else {
                        VStack(spacing: 6) {
                            ForEach(Array(recent)) { e in
                                HStack {
                                    Text(e.ts, format: .dateTime.month().day().hour().minute())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 110, alignment: .leading)
                                    Text(e.app.isEmpty ? "—" : e.app)
                                        .frame(width: 140, alignment: .leading)
                                        .lineLimit(1)
                                    if e.mode == "prompt" {
                                        Text("PROMPT")
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Color.purple.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                                    }
                                    Spacer()
                                    Text("\(e.words) words").foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .padding(20)
        }
    }

    private var timeSavedText: String {
        let sec = store.totalTimeSavedSec
        if sec < 60 { return "\(Int(sec))s" }
        if sec < 3600 { return "\(Int(sec / 60))m" }
        return String(format: "%.1fh", sec / 3600)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
