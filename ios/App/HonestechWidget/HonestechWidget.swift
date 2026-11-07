import WidgetKit
import SwiftUI

// Home Screen and Lock Screen widgets: the next job and the rest of today.
// The app writes the schedule (SharedSchedule.swift); the widget only reads it.

struct HTEntry: TimelineEntry {
    let date: Date
    let snap: HTWidgetSnapshot?
}

struct HTProvider: TimelineProvider {
    func placeholder(in context: Context) -> HTEntry { HTEntry(date: Date(), snap: HTSample.snap) }

    func getSnapshot(in context: Context, completion: @escaping (HTEntry) -> Void) {
        let s = HTShared.read()
        completion(HTEntry(date: Date(), snap: (context.isPreview && (s?.jobs.isEmpty ?? true)) ? HTSample.snap : s))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HTEntry>) -> Void) {
        let now = Date()
        let snap = HTShared.read()
        // a new entry each time a job finishes, so "Next up" moves on by itself
        var dates: [Date] = [now]
        for j in snap?.jobs ?? [] where j.end > now { dates.append(j.end) }
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: now.addingTimeInterval(86_400))
        dates.append(midnight)
        dates = Array(Set(dates)).filter { $0 >= now && $0 <= midnight }.sorted()
        let entries = dates.prefix(30).map { HTEntry(date: $0, snap: snap) }
        // check back by midnight, or within 2 hours, whichever is first
        completion(Timeline(entries: Array(entries), policy: .after(min(midnight, now.addingTimeInterval(7200)))))
    }
}

enum HTSample {
    static var snap: HTWidgetSnapshot {
        let t = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        var s = HTWidgetSnapshot()
        s.signedIn = true
        s.jobs = [
            HTWidgetJob(id: "a", s: t.timeIntervalSince1970 * 1000, e: nil, n: "Sarah Johnson", c: "2018 Toyota RAV4", w: "Front brakes", a: "14 Elm St, Freehold"),
            HTWidgetJob(id: "b", s: t.addingTimeInterval(9000).timeIntervalSince1970 * 1000, e: nil, n: "Mike Flinn", c: "2015 Jeep Cherokee", w: "Coolant leak", a: nil),
            HTWidgetJob(id: "c", s: t.addingTimeInterval(14400).timeIntervalSince1970 * 1000, e: nil, n: "Jason Miller", c: "2020 Honda Civic", w: "Oil change", a: nil)
        ]
        return s
    }
}

// MARK: - what to show at a given moment

struct HTView {
    let now: Date
    let snap: HTWidgetSnapshot?
    var signedIn: Bool { snap?.signedIn ?? (snap != nil) }
    var upcoming: [HTWidgetJob] {
        (snap?.jobs ?? []).filter { $0.on == true || $0.end > now }
            .sorted { ($0.on == true ? 0 : 1, $0.s) < ($1.on == true ? 0 : 1, $1.s) }
    }
    var next: HTWidgetJob? { upcoming.first }
    var today: [HTWidgetJob] { upcoming.filter { Calendar.current.isDate($0.start, inSameDayAs: now) } }
    var moreToday: Int { max(0, today.count - 1) }
    var accent: Color { Color(hex: snap?.accent) ?? Color(red: 0.11, green: 0.37, blue: 0.66) }

    func isNow(_ j: HTWidgetJob) -> Bool { j.on == true || (j.nt != true && j.start <= now && j.end > now) }
    func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = Calendar.current.component(.minute, from: d) == 0 ? "h a" : "h:mm a"
        return f.string(from: d)
    }
    func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: d)
    }
    func when(_ j: HTWidgetJob) -> String {
        if isNow(j) { return "Now" }
        if j.nt == true { return day(j.start) }
        return Calendar.current.isDate(j.start, inSameDayAs: now) ? time(j.start) : day(j.start) + " " + time(j.start)
    }
    func link(_ j: HTWidgetJob?) -> URL { URL(string: j.map { "honestech://job/\($0.id)" } ?? "honestech://open")! }
}

extension Color {
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

extension View {
    // iOS 17+ draws the background and margins itself; older versions need them added
    @ViewBuilder func htBackground(lock: Bool) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(for: .widget) { lock ? Color.clear : Color(UIColor.systemBackground) }
        } else if lock {
            self
        } else {
            self.padding().background(Color(UIColor.systemBackground))
        }
    }
}

// MARK: - Home Screen

struct HTHeader: View {
    let v: HTView
    let title: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 11, weight: .bold))
            Text(title).font(.system(size: 11, weight: .heavy)).textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .foregroundColor(v.accent)
    }
}

struct HTNextBlock: View {
    let v: HTView
    let j: HTWidgetJob
    var big = true
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v.when(j)).font(.system(size: big ? 24 : 20, weight: .bold)).minimumScaleFactor(0.6).lineLimit(1)
            Text(j.n).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            if let c = j.c, !c.isEmpty { Text(c).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1) }
            if let w = j.w, !w.isEmpty { Text(w).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1) }
            if j.h == true {
                Label("Not signed yet", systemImage: "hourglass").font(.system(size: 11, weight: .semibold)).foregroundColor(.orange).lineLimit(1)
            }
        }
    }
}

struct HTEmpty: View {
    let v: HTView
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !v.signedIn {
                Text("Open Honestech to sign in").font(.system(size: 14, weight: .semibold))
            } else {
                Text("No jobs coming up").font(.system(size: 15, weight: .semibold))
                Text("Booked jobs show here.").font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }
}

struct HTRow: View {
    let v: HTView
    let j: HTWidgetJob
    var body: some View {
        Link(destination: v.link(j)) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(v.when(j)).font(.system(size: 12, weight: .bold)).frame(width: 62, alignment: .leading).lineLimit(1).minimumScaleFactor(0.7)
                VStack(alignment: .leading, spacing: 0) {
                    Text(j.n).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let c = j.c, !c.isEmpty { Text(c).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if j.h == true { Image(systemName: "hourglass").font(.system(size: 10)).foregroundColor(.orange) }
            }
        }
    }
}

struct HTSmall: View {
    let v: HTView
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HTHeader(v: v, title: v.next.map { v.isNow($0) ? "Now" : "Next up" } ?? "Schedule")
            if let j = v.next { HTNextBlock(v: v, j: j) } else { HTEmpty(v: v) }
            Spacer(minLength: 0)
            if v.moreToday > 0 {
                Text("+\(v.moreToday) more today").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(v.link(v.next))
    }
}

struct HTMedium: View {
    let v: HTView
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HTHeader(v: v, title: v.next.map { v.isNow($0) ? "Now" : "Next up" } ?? "Schedule")
                if let j = v.next { HTNextBlock(v: v, j: j, big: false) } else { HTEmpty(v: v) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let rest = Array(v.upcoming.dropFirst().prefix(3))
            if !rest.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(v.moreToday > 0 ? "Later today" : "Coming up").font(.system(size: 11, weight: .heavy)).textCase(.uppercase).foregroundColor(.secondary)
                    ForEach(rest, id: \.self) { HTRow(v: v, j: $0) }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(v.link(v.next))
    }
}

struct HTLarge: View {
    let v: HTView
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HTHeader(v: v, title: "Schedule")
            if let j = v.next {
                Link(destination: v.link(j)) { HTNextBlock(v: v, j: j) }
                Divider()
                let rest = Array(v.upcoming.dropFirst().prefix(5))
                ForEach(rest, id: \.self) { HTRow(v: v, j: $0) }
            } else {
                HTEmpty(v: v)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if let n = v.snap?.req, n > 0 { Label("\(n) new request\(n == 1 ? "" : "s")", systemImage: "tray.and.arrow.down") }
                if let n = v.snap?.wait, n > 0 { Label("\(n) waiting", systemImage: "hourglass") }
                if let n = v.snap?.owed, n > 0 { Label("\(n) unpaid", systemImage: "dollarsign.circle") }
            }
            .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(v.link(v.next))
    }
}

// MARK: - Lock Screen (iOS 16+)

@available(iOSApplicationExtension 16.0, *)
struct HTLockRect: View {
    let v: HTView
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let j = v.next {
                Label(v.isNow(j) ? "Now" : "Next · " + v.when(j), systemImage: "wrench.and.screwdriver.fill").font(.system(size: 13, weight: .bold)).lineLimit(1)
                Text(j.n).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(j.c ?? j.w ?? "").font(.system(size: 12)).lineLimit(1)
            } else {
                Label("Honestech", systemImage: "wrench.and.screwdriver.fill").font(.system(size: 13, weight: .bold))
                Text(v.signedIn ? "No jobs coming up" : "Open to sign in").font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(v.link(v.next))
    }
}

@available(iOSApplicationExtension 16.0, *)
struct HTLockCircle: View {
    let v: HTView
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text("\(v.today.count)").font(.system(size: 20, weight: .bold))
                Text(v.today.count == 1 ? "job" : "jobs").font(.system(size: 10, weight: .semibold))
            }
        }
        .widgetURL(v.link(v.next))
    }
}

struct HTWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: HTEntry
    var body: some View {
        let v = HTView(now: entry.date, snap: entry.snap)
        content(v).htBackground(lock: isLock)
    }

    var isLock: Bool {
        if #available(iOSApplicationExtension 16.0, *) {
            return family == .accessoryRectangular || family == .accessoryCircular || family == .accessoryInline
        }
        return false
    }

    @ViewBuilder func content(_ v: HTView) -> some View {
        if #available(iOSApplicationExtension 16.0, *) {
            switch family {
            case .accessoryRectangular: HTLockRect(v: v)
            case .accessoryCircular: HTLockCircle(v: v)
            case .accessoryInline:
                if let j = v.next { Text("\(v.isNow(j) ? "Now" : v.when(j)) · \(j.n)") } else { Text("No jobs coming up") }
            default: home(v)
            }
        } else {
            home(v)
        }
    }

    @ViewBuilder func home(_ v: HTView) -> some View {
        switch family {
        case .systemMedium: HTMedium(v: v)
        case .systemLarge: HTLarge(v: v)
        default: HTSmall(v: v)
        }
    }
}

struct HonestechScheduleWidget: Widget {
    let kind = "HonestechSchedule"
    var families: [WidgetFamily] {
        var f: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        if #available(iOSApplicationExtension 16.0, *) { f += [.accessoryRectangular, .accessoryCircular, .accessoryInline] }
        return f
    }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HTProvider()) { HTWidgetView(entry: $0) }
            .configurationDisplayName("Next job")
            .description("Your next job and the rest of today.")
            .supportedFamilies(families)
    }
}

@main
struct HonestechWidgets: WidgetBundle {
    var body: some Widget { HonestechScheduleWidget() }
}
