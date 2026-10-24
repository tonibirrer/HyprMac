import Carbon
import XCTest
@testable import HyprMac

// issue #28: rebinding Cycle Floating (hypr+shift+t) without shift put it on
// toggle floating's chord. a keybind's id is its chord, so the two rows shared
// an id, the next edit overwrote whichever bind came first on that chord, and
// the list filled with copies of one bind while another disappeared.
final class KeybindEditingTests: XCTestCase {
    private let toggle = Keybind(keyCode: UInt16(kVK_ANSI_T), modifiers: .hypr, action: .toggleFloating)
    private let cycle = Keybind(keyCode: UInt16(kVK_ANSI_T), modifiers: [.hypr, .shift], action: .focusFloating)
    private var cycleWithoutShift: Keybind {
        Keybind(keyCode: UInt16(kVK_ANSI_T), modifiers: .hypr, action: .focusFloating)
    }

    func testTheDefaultsHoldBothFloatingBinds() {
        XCTAssertTrue(Keybind.defaults.contains(toggle))
        XCTAssertTrue(Keybind.defaults.contains(cycle))
    }

    @MainActor
    func testDroppingShiftOntoAnotherBindsChordIsAConflict() {
        let vm = KeybindEditorViewModel()
        vm.load(cycle)
        vm.useShift = false

        XCTAssertEqual(vm.conflict(in: Keybind.defaults, editing: cycle), toggle)
    }

    @MainActor
    func testAnEditThatKeepsItsOwnChordIsNotAConflict() {
        let vm = KeybindEditorViewModel()
        vm.load(cycle)
        vm.selectedAction = .toggleTiling

        XCTAssertNil(vm.conflict(in: Keybind.defaults, editing: cycle))
    }

    @MainActor
    func testANewBindOnATakenChordIsAConflict() {
        let vm = KeybindEditorViewModel()
        vm.recordedKeyCode = UInt16(kVK_ANSI_T)
        vm.selectedAction = .closeWindow

        XCTAssertEqual(vm.conflict(in: Keybind.defaults, editing: nil), toggle)
    }

    func testAnEditReplacesTheEditedBindNotTheFirstOneOnItsChord() {
        // a config already saved with two binds on hypr+t
        let binds = [toggle, cycleWithoutShift]

        let edited = binds.replacingBind(cycleWithoutShift, with: cycle)

        XCTAssertEqual(edited, [toggle, cycle], "toggle floating survives the edit")
    }

    func testDeletingABindLeavesAnotherBindOnTheSameChord() {
        let binds = [toggle, cycleWithoutShift, cycleWithoutShift]

        XCTAssertEqual(binds.removingBind(cycleWithoutShift), [toggle])
    }
}
