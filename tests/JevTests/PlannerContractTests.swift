@testable import vphone_cli
import CoreGraphics
import Foundation
import Testing

@MainActor
struct PlannerContractTests {
    func space(_ observation: JevObservation) -> JevActionSpace {
        JevActionSpace(observation: observation, apps: [("editor.app", "Editor")],
            textCandidates: ["First literal", "Second literal"], pickerValues: ["15", "30"])
    }
    func step(_ binding: JevPlannerDecider.Binding, value: String? = nil) -> JevPlannerDecider.Step {
        .init(operation: binding.operation.rawValue, targetKey: binding.key,
            expectedValue: value ?? binding.offered.ownerValue, afterValue: nil, inspection: false, subgoal: "One action")
    }
    func decision(_ binding: JevPlannerDecider.Binding) -> JevStepDecision {
        .init(action: binding.operation, confidence: 0.99, done: 0, blocked: 0, risky: 0,
            targetId: binding.target?.elementID, appId: binding.target?.appID, textId: binding.target?.textID,
            pickerValue: binding.operation == .setPickerValue ? binding.target?.value : nil)
    }
    func observation() -> JevObservation {
        var raw = ControlMemoryTests().observation("Selected item A")
        raw.elements += [
            JevElement(id: "save", role: "button", label: "Save", value: nil, point: .zero),
            JevElement(id: "field", role: "textfield", label: "Title", value: "Original", point: .zero),
            JevElement(id: "minute", role: "picker", label: "Minute", value: "00", point: .zero,
                pickerOptions: ["00", "15", "30"]),
        ]
        raw.supportsPickerSelection = true
        return raw
    }

    @Test func bindingCoversEveryOfferedOperationAndCompleteSemanticSelection() throws {
        let raw = observation(), actionSpace = space(observation())
        let bindings = JevPlannerDecider.bindings(observation: raw, space: actionSpace)
        #expect(Set(bindings.map(\.operation)) == Set(actionSpace.operations.filter { $0 != .finish }))
        for binding in bindings {
            let resolved = try JevPlannerDecider.resolve(step(binding), bindings: bindings, observation: raw)
            #expect(resolved.matches(decision(binding)))
            #expect(!resolved.matches(.init(action: .finish, confidence: 1, done: 1, blocked: 0, risky: 0)))
        }
        for operation in [JevAction.typeText, .setPickerValue, .openApp, .tap] {
            let binding = try #require(bindings.first { $0.operation == operation })
            let target = binding.target
            let wrongElement = JevStepDecision(action: operation, confidence: 1, done: 0, blocked: 0, risky: 0,
                targetId: "another element", appId: target?.appID, textId: target?.textID,
                pickerValue: operation == .setPickerValue ? target?.value : nil)
            #expect(!binding.matches(wrongElement))
            if operation == .typeText {
                let swapped = JevStepDecision(action: operation, confidence: 1, done: 0, blocked: 0, risky: 0,
                    targetId: target?.elementID, textId: "different literal")
                #expect(!binding.matches(swapped))
            }
            if operation == .setPickerValue {
                let swapped = JevStepDecision(action: operation, confidence: 1, done: 0, blocked: 0, risky: 0,
                    targetId: target?.elementID, pickerValue: "45")
                #expect(!binding.matches(swapped))
            }
            if operation == .openApp {
                #expect(!binding.matches(.init(action: operation, confidence: 1, done: 0, blocked: 0, risky: 0, appId: "other.app")))
            }
        }
    }

    @Test func namedOwnerUsesExplicitIdentityAndRejectsWrongValueOrAmbiguity() throws {
        let raw = observation()
        let bindings = JevPlannerDecider.bindings(observation: raw, space: space(raw))
        let binding = try #require(bindings.first { $0.element?.customAction?.name == "Activate" })
        #expect(binding.owner?.id == "owner")
        #expect(binding.element?.customAction?.ownerID == "owner")
        #expect(throws: (any Error).self) {
            _ = try JevPlannerDecider.resolve(step(binding, value: "Selected item B"), bindings: bindings, observation: raw)
        }
        var duplicate = raw
        duplicate.elements.append(JevElement(id: "other-owner", role: "statictext", label: "Selection", value: "Other item",
            point: .zero, context: "Canvas"))
        let ambiguous = JevPlannerDecider.bindings(observation: duplicate, space: space(duplicate))
        #expect(throws: (any Error).self) {
            _ = try JevPlannerDecider.resolve(step(binding), bindings: ambiguous, observation: duplicate)
        }
        var missing = raw
        let index = try #require(missing.elements.firstIndex { $0.id == binding.element?.id })
        missing.elements[index].customAction?.ownerID = nil
        let unbound = JevPlannerDecider.bindings(observation: missing, space: space(missing))
        #expect(throws: (any Error).self) {
            _ = try JevPlannerDecider.resolve(step(binding), bindings: unbound, observation: missing)
        }
    }

    @Test func disagreementWaitsWithoutOverridingJevAndReplansWithRejectionEvidence() async throws {
        let fixture = PlannerTests(), base = PlannerTests.Base()
        let decider = JevPlannerDecider(base: base, executable: "/unused")
        var requests: [[String: Any]] = []
        decider.requestOverride = { data in
            requests.append(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
            return fixture.reply(to: data)
        }
        base.decision = .init(action: .tap, confidence: 0.9, done: 0, blocked: 0.3, risky: 0.7,
            targetId: "owner:action2", inputTokens: 29)
        let rejected = await fixture.decide(decider)
        #expect(rejected.action == .wait && rejected.done == 0 && rejected.targetId == nil)
        #expect(rejected.blocked == 0.3 && rejected.risky == 0.7 && rejected.inputTokens == 29)
        #expect(decider.lastContractRejection?.contains("No input was executed") == true)
        base.decision = .init(action: .tap, confidence: 0.9, done: 0, blocked: 0, risky: 0, targetId: "owner:action1")
        let accepted = await fixture.decide(decider)
        #expect(accepted.action == .tap && accepted.targetId == "owner:action1")
        #expect(requests.count == 2)
        #expect((requests[1]["state"] as? [String: Any])?["inputRejection"] as? String != fixture.state().inputRejection)
        #expect(requests[0]["protocol_version"] as? Int == 2)
        #expect(requests[0]["observation_id"] as? String != requests[1]["observation_id"] as? String)
        let actions = try #require(requests[0]["offered_actions"] as? [[String: Any]])
        let owner = try #require(actions.first { $0["target_key"] as? String == "owner:action1" })
        #expect(owner["owner_id"] as? String == "owner")
        #expect(owner["owner_value"] as? String == "Current item")
        let home = try #require(actions.first { $0["operation"] as? String == "press_home" })
        #expect(home["target_key"] is NSNull && home["owner_id"] is NSNull && home["owner_value"] is NSNull)
    }

    @Test func pickerCandidatesComeFromOriginalGoalUnderPlannerSubgoal() {
        var state = PlannerTests().state()
        state.plannerContext = .init(originalGoal: "Set time to 9:15 and then 10:30", proposedReasoning: nil)
        #expect(JevModelDecider.pickerValues(in: state) == JevPickerValues.extract(from: state.plannerContext!.originalGoal))
        state.plannerContext = nil
        #expect(JevModelDecider.pickerValues(in: state) == JevPickerValues.extract(from: state.goal))
    }
}
