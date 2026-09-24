import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
@Suite("Linux pick.open")
struct LinuxControlPickTests {
    private let items = [ControlPickItem(id: "a", label: "alpha"), ControlPickItem(id: "b", label: "beta"),
                         ControlPickItem(id: "c", label: "gamma")]

    private func refusal(_ args: ControlArgs) -> String? {
        guard case .failure(let refusal) = LinuxControlDispatcher.pendingPick(from: args) else { return nil }
        return refusal.message
    }

    @Test("--select carries the chosen item id into the pending pick")
    func selectionCarried() throws {
        let pick = try LinuxControlDispatcher.pendingPick(from: ControlArgs(items: items, selection: "c"), id: "p")
            .get()
        #expect(pick.selection == "c")
        #expect(pick.id == "p")
    }

    @Test("a selection naming no supplied item refuses the open")
    func unknownSelection() {
        #expect(refusal(ControlArgs(items: items, selection: "z")) == "pick select must name an item id")
        #expect(refusal(ControlArgs(items: [], allowCustom: true, selection: "a"))
            == "pick select must name an item id")
        #expect(refusal(ControlArgs(items: [], selection: "a")) == "pick.open requires at least one item")
    }

    @Test("the picker opens on the selected row, and on the first row when a query hides it")
    func seededRow() {
        let rows = items.enumerated().map {
            LinuxControlPickRow(item: $0.element, originalIndex: $0.offset, customQuery: nil)
        }
        #expect(LinuxControlPickRow.seededIndex(selection: "c", in: rows) == 2)
        #expect(LinuxControlPickRow.seededIndex(selection: "c", in: Array(rows.prefix(2))) == nil)
        #expect(LinuxControlPickRow.seededIndex(selection: nil, in: rows) == nil)
    }
}
