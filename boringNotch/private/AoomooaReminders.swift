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

    /// 日期条显示几周：本周之前 / 之后各几周（每次左右滑翻一整周）
    static let weeksBefore = 1
    static let weeksAfter = 2
    static var weekCount: Int { weeksBefore + 1 + weeksAfter }

    /// 日期条的第一天：本周第一天（跟随系统设置）往前 weeksBefore 周
    static func stripStart(today: Date = Date()) -> Date {
        let cal = Calendar.current
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? cal.startOfDay(for: today)
        return cal.date(byAdding: .weekOfYear, value: -weeksBefore, to: weekStart) ?? weekStart
    }

    /// 某一天在日期条的第几周
    static func weekIndex(of day: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: stripStart(), to: cal.startOfDay(for: day)).day ?? 0
        return min(max(days / 7, 0), weekCount - 1)
    }
    /// 勾选后先停留这么久（看得到对勾）再从列表移除
    static let completeLinger: Double = 0.45

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
                withAnimation(DS.Motion.micro) { self.recompute() }
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
        let start = Self.stripStart()
        guard let end = cal.date(byAdding: .day, value: Self.weekCount * 7, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        allEvents = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        withAnimation(DS.Motion.micro) { recompute() }
    }

    func selectDay(_ day: Date) {
        withAnimation(DS.Motion.micro) {
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
        withAnimation(DS.Motion.micro) { _ = completingIDs.insert(id) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.completeLinger))
            reminder.isCompleted = true
            do {
                try store.save(reminder, commit: true)
            } catch {
                reminder.isCompleted = false
            }
            withAnimation(DS.Motion.micro) {
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
            withAnimation(DS.Motion.micro) { recompute() }
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
        VStack(alignment: .leading, spacing: DS.Space.s) {
            calendarHeader

            if model.items.isEmpty && model.dayEvents.isEmpty {
                VStack(spacing: DS.Space.xs) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(DS.Fonts.body)
                        .foregroundStyle(DS.Colors.textSecondary)
                    Text(emptyText)
                        .font(DS.Fonts.body)
                        .foregroundStyle(DS.Colors.textSecondary)
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
        HStack(spacing: DS.Space.s) {
            Image(systemName: "plus")
                .font(DS.Fonts.caption(.semibold))
                .foregroundStyle(DS.Colors.textSecondary)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(DS.Fonts.body)
                .foregroundStyle(DS.Colors.textPrimary)
                .focused($inputFocused)
                .onSubmit {
                    model.add(draft)
                    draft = ""
                }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Colors.fill))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
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

    // MARK: 日历：月份 + 按周分页的日期条（原生滚动，没有自定义弹簧）

    private var calendarHeader: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            Text(formatter("M月").string(from: model.selectedDay))
                .font(DS.Fonts.title)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize()
            dayStrip
        }
    }

    private var weeks: [[Date]] {
        let cal = Calendar.current
        let start = NotchRemindersModel.stripStart()
        return (0..<NotchRemindersModel.weekCount).map { week in
            (0..<7).compactMap { cal.date(byAdding: .day, value: week * 7 + $0, to: start) }
        }
    }

    private var dayStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { index, days in
                        HStack(spacing: 0) {
                            ForEach(days, id: \.self) { day in
                                dayItem(day)
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selectDay(day) }
                                    .onHover { inside in
                                        if inside { hoveredDay = day } else if hoveredDay == day { hoveredDay = nil }
                                    }
                            }
                        }
                        .containerRelativeFrame(.horizontal)
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            // 原生分页：一次翻一整周，松手干脆地停在周的边界上
            .scrollTargetBehavior(.paging)
            .frame(height: DS.Size.dayStripHeight)
            .onHover { inside in model.isHoveringDayStrip = inside }
            .onDisappear { model.isHoveringDayStrip = false }
            .onAppear {
                proxy.scrollTo(NotchRemindersModel.weekIndex(of: model.selectedDay), anchor: .leading)
            }
            .onChange(of: model.selectedDay) { _, day in
                withAnimation(DS.Motion.page) {
                    proxy.scrollTo(NotchRemindersModel.weekIndex(of: day), anchor: .leading)
                }
            }
        }
    }

    /// 和系统日历一样：今天 = 红色实心圆，选中 = 浅色圆，有日程 = 下面一个红点
    private func dayItem(_ day: Date) -> some View {
        let cal = Calendar.current
        let selected = cal.isDate(day, inSameDayAs: model.selectedDay)
        let isToday = cal.isDateInToday(day)
        let busy = model.busyDays.contains(cal.startOfDay(for: day))
        let circle: Color = isToday ? DS.Colors.accent
            : selected ? DS.Colors.fillHover
            : hoveredDay == day ? DS.Colors.fill
            : Color.clear

        return VStack(spacing: 0) {
            Text(formatter("EEEEE").string(from: day))
                .font(DS.Fonts.caption)
                .foregroundStyle(isToday || selected ? DS.Colors.textSecondary : DS.Colors.textTertiary)
            Text(String(cal.component(.day, from: day)))
                .font(DS.Fonts.body(isToday || selected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isToday || selected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .frame(width: DS.Size.dayCircle, height: DS.Size.dayCircle)
                .background(Circle().fill(circle))
            Circle()
                .fill(busy ? DS.Colors.accent : Color.clear)
                .frame(width: DS.Size.dot, height: DS.Size.dot)
        }
    }

    // MARK: Rows

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(spacing: DS.Space.s) {
            Capsule()
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: DS.Size.eventBar, height: DS.Size.rowIcon)
            Text(event.title ?? "")
                .font(DS.Fonts.body)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.xs)
            Text(event.isAllDay ? "全天" : time(event.startDate))
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(.vertical, DS.Space.xs)
        .padding(.leading, DS.Space.xs)
        .transition(.opacity)
    }

    private func row(_ reminder: EKReminder) -> some View {
        let done = model.completingIDs.contains(reminder.calendarItemIdentifier)
        return HStack(spacing: DS.Space.s) {
            Button {
                model.complete(reminder)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(DS.Fonts.body)
                    .foregroundStyle(done ? DS.Colors.success : DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)

            Text(reminder.title ?? "")
                .font(DS.Fonts.body)
                .foregroundStyle(done ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                .strikethrough(done, color: DS.Colors.textSecondary)
                .lineLimit(1)

            Spacer(minLength: DS.Space.xs)

            if let due = dueText(reminder) {
                Text(due)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(due == "已过期" ? DS.Colors.warning : DS.Colors.textSecondary)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
        .transition(.opacity)
    }

    private var deniedView: some View {
        VStack(spacing: DS.Space.s) {
            Text("没有提醒事项的访问权限")
                .font(DS.Fonts.body)
                .foregroundStyle(DS.Colors.textSecondary)
            Button("打开系统设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.plain)
            .font(DS.Fonts.body(.medium))
            .foregroundStyle(DS.Colors.accent)
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
