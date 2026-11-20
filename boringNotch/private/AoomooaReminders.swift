//
//  AoomooaReminders.swift
//  boringNotch (aoomooa fork)
//
//  Left side of the Workspace tab: Apple Reminders + a swipeable day strip (±5 days)
//  with that day's calendar events. Syncs with iPhone via iCloud.
//

import AppKit
import EventKit
import SwiftUI

@MainActor
final class NotchRemindersModel: ObservableObject {
    static let shared = NotchRemindersModel()

    enum Access { case unknown, granted, denied }

    /// Days shown either side of today in the strip
    static let dayRange = 5

    @Published private(set) var items: [EKReminder] = []
    @Published private(set) var dayEvents: [EKEvent] = []
    @Published private(set) var busyDays: Set<Date> = []
    @Published private(set) var access: Access = .unknown
    @Published private(set) var calendarAccess: Access = .unknown
    @Published private(set) var completingIDs: Set<String> = []
    @Published private(set) var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    /// True while the mouse is over the day strip (its horizontal scroll shouldn't switch tabs)
    var isHoveringDayStrip = false

    let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var allIncomplete: [EKReminder] = []
    private var allEvents: [EKEvent] = []

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
                self?.reloadEvents()
            }
        }
    }

    // MARK: Permissions

    func start() {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            access = .granted
            reload()
        case .notDetermined:
            Task { @MainActor in
                let ok = (try? await store.requestFullAccessToReminders()) ?? false
                access = ok ? .granted : .denied
                if ok { reload() }
                requestCalendarIfNeeded()
            }
            return
        default:
            access = .denied
        }
        requestCalendarIfNeeded()
    }

    private func requestCalendarIfNeeded() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            calendarAccess = .granted
            reloadEvents()
        case .notDetermined:
            Task { @MainActor in
                let ok = (try? await store.requestFullAccessToEvents()) ?? false
                calendarAccess = ok ? .granted : .denied
                reloadEvents()
            }
        default:
            calendarAccess = .denied
        }
    }

    // MARK: Data

    func reload() {
        guard access == .granted else { return }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] result in
            let sorted = (result ?? []).sorted { a, b in
                let da = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                let db = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                if da != db { return da < db }
                return (a.creationDate ?? .distantPast) > (b.creationDate ?? .distantPast)
            }
            Task { @MainActor in
                guard let self else { return }
                self.allIncomplete = sorted
                withAnimation(.smooth) { self.recompute() }
            }
        }
    }

    func reloadEvents() {
        guard calendarAccess == .granted else {
            allEvents = []
            recompute()
            return
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -Self.dayRange, to: today),
              let end = cal.date(byAdding: .day, value: Self.dayRange + 1, to: today) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        allEvents = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        withAnimation(.smooth) { recompute() }
    }

    func selectDay(_ day: Date) {
        withAnimation(.smooth(duration: 0.25)) {
            selectedDay = Calendar.current.startOfDay(for: day)
            recompute()
        }
    }

    /// Today: overdue + today + undated reminders. Other days: reminders due that day.
    private func recompute() {
        let cal = Calendar.current
        let day = selectedDay
        let isToday = cal.isDateInToday(day)
        let nextDay = cal.date(byAdding: .day, value: 1, to: day) ?? day

        items = allIncomplete.filter { r in
            guard let c = r.dueDateComponents, let d = cal.date(from: c) else { return isToday }
            return isToday ? d < nextDay : cal.isDate(d, inSameDayAs: day)
        }
        dayEvents = allEvents.filter { e in
            e.startDate < nextDay && e.endDate > day
        }

        var busy = Set<Date>()
        for e in allEvents {
            busy.insert(cal.startOfDay(for: e.startDate))
        }
        for r in allIncomplete {
            if let c = r.dueDateComponents, let d = cal.date(from: c) {
                busy.insert(cal.startOfDay(for: d))
            }
        }
        busyDays = busy
    }

    /// True when new reminders land in a list that syncs to your other Apple devices (iCloud/CalDAV/Exchange)
    var defaultListSyncs: Bool {
        guard access == .granted, let source = store.defaultCalendarForNewReminders()?.source else { return true }
        return source.sourceType == .calDAV || source.sourceType == .exchange
    }

    // MARK: Actions

    func complete(_ reminder: EKReminder) {
        let id = reminder.calendarItemIdentifier
        withAnimation(.smooth(duration: 0.2)) { _ = completingIDs.insert(id) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            reminder.isCompleted = true
            do {
                try store.save(reminder, commit: true)
            } catch {
                reminder.isCompleted = false
            }
            withAnimation(.smooth) {
                if reminder.isCompleted {
                    allIncomplete.removeAll { $0.calendarItemIdentifier == id }
                    recompute()
                }
                completingIDs.remove(id)
            }
        }
    }

    /// New reminders get the selected day as due date (unless it's today)
    func add(_ title: String) {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, access == .granted,
              let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = list
        if !Calendar.current.isDateInToday(selectedDay) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: selectedDay)
        }
        do {
            try store.save(reminder, commit: true)
            allIncomplete.insert(reminder, at: 0)
            withAnimation(.smooth) { recompute() }
        } catch {
            // ignore; the list simply won't change
        }
    }
}

struct NotchRemindersView: View {
    @ObservedObject private var model = NotchRemindersModel.shared
    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    @State private var hoveredDay: Date?

    var body: some View {
        Group {
            if model.access == .denied {
                deniedView
            } else {
                listView
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.start() }
        .onDisappear {
            inputFocused = false
            // give keyboard focus back so typing never lands in a closed notch
            for window in NSApp.windows where window.isKeyWindow && window is BoringNotchSkyLightWindow {
                window.resignKey()
            }
        }
    }

    private var listView: some View {
        VStack(alignment: .leading, spacing: 6) {
            calendarHeader

            if model.items.isEmpty && model.dayEvents.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.gray)
                    Text(emptyText)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.dayEvents, id: \.eventIdentifier) { event in
                            eventRow(event)
                        }
                        ForEach(model.items, id: \.calendarItemIdentifier) { reminder in
                            row(reminder)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            inputField
        }
    }

    private var inputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.gray)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.white)
                .focused($inputFocused)
                .onSubmit {
                    model.add(draft)
                    draft = ""
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .contentShape(Capsule())
        .onTapGesture { inputFocused = true }
    }

    private var placeholder: String {
        let local = model.defaultListSyncs ? "" : "·仅存本机"
        return Calendar.current.isDateInToday(model.selectedDay)
            ? "新提醒\(local)…"
            : "新提醒（\(shortDate(model.selectedDay))）\(local)…"
    }

    private var emptyText: String {
        if model.access != .granted { return "正在连接提醒事项…" }
        return Calendar.current.isDateInToday(model.selectedDay) ? "今天没有任何事项" : "这天没有安排"
    }

    // MARK: Calendar header — big month + swipeable day row

    private var calendarHeader: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(formatter("M月").string(from: model.selectedDay))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .fixedSize()
                .contentTransition(.numericText())
            dayStrip
        }
    }

    private var dayStrip: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = (-NotchRemindersModel.dayRange...NotchRemindersModel.dayRange)
            .compactMap { cal.date(byAdding: .day, value: $0, to: today) }

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        dayItem(day)
                            .id(day)
                            .onTapGesture { model.selectDay(day) }
                            .onHover { inside in
                                withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.8)) {
                                    if inside { hoveredDay = day } else if hoveredDay == day { hoveredDay = nil }
                                }
                            }
                    }
                }
                .padding(.horizontal, 10)
            }
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.12),
                                       .init(color: .black, location: 0.88),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .onHover { inside in model.isHoveringDayStrip = inside }
            .onDisappear { model.isHoveringDayStrip = false }
            .onAppear { proxy.scrollTo(model.selectedDay, anchor: .center) }
            .onChange(of: model.selectedDay) { _, day in
                withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(day, anchor: .center) }
            }
        }
        .frame(height: 40)
    }

    /// Weekday over the date; today in system red, the selected day big and white
    private func dayItem(_ day: Date) -> some View {
        let cal = Calendar.current
        let selected = cal.isDate(day, inSameDayAs: model.selectedDay)
        let isToday = cal.isDateInToday(day)
        let busy = model.busyDays.contains(cal.startOfDay(for: day))
        let red = Color(nsColor: .systemRed)
        let emphasised = selected || isToday
        let numberColor: Color = isToday ? red : (selected ? Color.white : Color.white.opacity(0.5))

        return VStack(spacing: 1) {
            Text(formatter("EEE").string(from: day))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(emphasised ? Color.white.opacity(0.85) : Color.gray.opacity(0.7))
            Text(String(format: "%02d", cal.component(.day, from: day)))
                .font(.system(size: emphasised ? 18 : 13, weight: emphasised ? .bold : .medium, design: .rounded))
                .foregroundStyle(numberColor)
            Circle()
                .fill(busy ? red : Color.clear)
                .frame(width: 3, height: 3)
        }
        .frame(width: 30)
        .scaleEffect(hoveredDay == day ? 1.15 : 1)
        .contentShape(Rectangle())
    }

    // MARK: Rows

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: 3, height: 14)
            Text(event.title ?? "")
                .font(.system(size: 13))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(event.isAllDay ? "全天" : time(event.startDate))
                .font(.system(size: 11))
                .foregroundStyle(Color.gray)
        }
        .padding(.vertical, 4)
        .padding(.leading, 5)
        .transition(.opacity)
    }

    private func row(_ reminder: EKReminder) -> some View {
        let done = model.completingIDs.contains(reminder.calendarItemIdentifier)
        return HStack(spacing: 8) {
            Button {
                model.complete(reminder)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(done ? Color.white : Color.gray)
            }
            .buttonStyle(.plain)

            Text(reminder.title ?? "")
                .font(.system(size: 13))
                .foregroundStyle(done ? Color.gray : Color.white)
                .strikethrough(done, color: Color.gray)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let due = dueText(reminder) {
                Text(due)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.gray)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .transition(.opacity)
    }

    private var deniedView: some View {
        VStack(spacing: 8) {
            Text("没有提醒事项的访问权限")
                .font(.system(size: 12))
                .foregroundStyle(Color.gray)
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Formatting

    private func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }

    private func weekday(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "今天" : formatter("EEE").string(from: date)
    }

    private func shortDate(_ date: Date) -> String {
        formatter("M月d日").string(from: date)
    }

    private func time(_ date: Date) -> String {
        formatter("HH:mm").string(from: date)
    }

    private func dueText(_ reminder: EKReminder) -> String? {
        guard let comps = reminder.dueDateComponents,
              let date = Calendar.current.date(from: comps) else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            guard comps.hour != nil else { return "今天" }
            return time(date)
        }
        if date < cal.startOfDay(for: Date()) { return "已过期" }
        if cal.isDateInTomorrow(date) { return "明天" }
        return shortDate(date)
    }
}
