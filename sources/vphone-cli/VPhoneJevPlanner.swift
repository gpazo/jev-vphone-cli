import Darwin
import Foundation

@MainActor
final class JevPlannerDecider: JevDecider {
    struct OfferedAction: Encodable {
        let operation: String
        let targetKey: String?
        let description: String
        let ownerID: String?
        let ownerValue: String?
        enum CodingKeys: String, CodingKey {
            case operation, description
            case targetKey = "target_key", ownerID = "owner_id", ownerValue = "owner_value"
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(operation, forKey: .operation); try c.encode(description, forKey: .description)
            try c.encode(targetKey, forKey: .targetKey); try c.encode(ownerID, forKey: .ownerID)
            try c.encode(ownerValue, forKey: .ownerValue)
        }
    }
    struct Request: Encodable {
        let protocolVersion = 2
        let observationID: String
        let offeredActions: [OfferedAction]
        let goal: String
        let state: JevState
        let maxNativeActions: Int
        let previousSubgoal: String?
        enum CodingKeys: String, CodingKey {
            case goal, state
            case protocolVersion = "protocol_version", observationID = "observation_id", offeredActions = "offered_actions"
            case maxNativeActions = "max_native_actions", previousSubgoal = "previous_subgoal"
        }
    }
    struct Step: Decodable {
        let operation: String
        let targetKey: String?
        let expectedValue: String?
        let afterValue: String?
        let inspection: Bool
        let subgoal: String
        enum CodingKeys: String, CodingKey {
            case operation, inspection, subgoal
            case targetKey = "target_key", expectedValue = "expected_value", afterValue = "after_value"
        }
    }
    struct Reply: Decodable {
        enum Status: String, Decodable { case continuePlan = "continue", complete, blocked }
        let status: Status
        let subgoal: String
        let reason: String
        let observationID: String
        let steps: [Step]
        enum CodingKeys: String, CodingKey {
            case status, subgoal, reason, steps
            case observationID = "observation_id"
        }
    }
    struct Binding {
        let operation: JevAction
        let key: String?
        let target: JevActionSpace.Target?
        let element: JevElement?
        let owner: JevElement?
        var offered: OfferedAction {
            OfferedAction(operation: operation.rawValue, targetKey: key,
                description: target?.description ?? operation.criterion,
                ownerID: element?.customAction?.ownerID, ownerValue: element?.customAction?.ownerValue ?? element?.value)
        }
        func matches(_ decision: JevStepDecision) -> Bool {
            decision.action == operation && decision.targetId == target?.elementID
                && decision.appId == target?.appID && decision.textId == target?.textID
                && decision.pickerValue == (operation == .setPickerValue ? target?.value : nil)
        }
    }
    struct Route {
        let steps: [Step]
        let bindings: [Binding]
        let guardEvidence: JevPlannerObservationGuard
        var index = 0
        var pendingToken: UUID?
        var acknowledged = false
    }
    struct ActionIdentity: Equatable {
        struct Node: Equatable {
            let role: String?
            let label: String
            let context: String?
            init(_ element: JevElement) {
                role = element.role; label = element.label; context = element.context
            }
        }
        let operation: JevAction
        let target: Node?
        let customAction: String?
        let owner: Node?
        let app: String?
        let payload: String?

        init(_ binding: Binding) {
            operation = binding.operation
            target = binding.element.map(Node.init)
            customAction = binding.element?.customAction?.name
            owner = binding.owner.map(Node.init)
            app = binding.target?.appID
            payload = binding.target?.value
        }
    }
    private struct RejectedProposal {
        let identity: ActionIdentity
        let evidence: JevPlannerObservationGuard
        let feedback: JevPlannerVisionFeedback
    }
    struct Failure: Error, CustomStringConvertible { let description: String }

    let base: any JevDecider
    let executable: String
    let policy: VPhoneJevAgent.Policy
    var requestOverride: (@MainActor (Data) async throws -> Data)?
    var name: String { "external planner + \(base.name)" }
    private var plans = 0
    private var subgoal: String?
    private var proposedReasoning: String?
    private var previousSubgoal: String?
    private var contract: Binding?
    private var route: Route?
    private var lastIssuedToken: UUID?
    private var traceID: String?
    private(set) var lastContractRejection: String?
    private var checkingOverallGoal = false
    private var rejectedProposals: [RejectedProposal] = []

    init(base: any JevDecider, executable: String, policy: VPhoneJevAgent.Policy = .default) {
        self.base = base; self.executable = executable; self.policy = policy
    }

    func decide(observation: JevObservation, state: JevState, apps: [(bundleId: String, name: String)],
                textCandidates: [String]) async -> JevStepDecision {
        guard rejectedProposals.count < policy.maxVisionRecoveries else {
            return .failed("Vision recovery limit reached")
        }
        traceID = UUID().uuidString
        var state = state
        state.unverifiedVisionFeedback = rejectedProposals.reversed().first {
            $0.evidence.rejection(in: observation) == nil
        }?.feedback
        let space = JevActionSpace(observation: observation, apps: apps, textCandidates: textCandidates,
            pickerValues: JevPickerValues.extract(from: state.goal))
        if !checkingOverallGoal, route != nil {
            do { contract = try resumeRoute(observation: observation, space: space) }
            catch { discardRoute("Route invalidated: \(error)") }
        }
        if !checkingOverallGoal && contract == nil {
            do {
                guard plans < policy.maxPlannerPlans else { throw Failure(description: "planner plan budget exhausted") }
                plans += 1
                let reply = try await plan(state, observation: observation, space: space)
                switch reply.status {
                case .blocked: return .failed("Planner blocked: \(reply.reason)")
                case .complete: checkingOverallGoal = true
                case .continuePlan:
                    subgoal = reply.steps[0].subgoal; previousSubgoal = reply.subgoal; proposedReasoning = reply.reason
                }
            } catch { discardRoute("Planner failed: \(error)"); return .failed("Planner failed: \(error)") }
        }
        let activeState = checkingOverallGoal ? state : replacingGoal(in: state, with: subgoal!)
        let decision = await base.decide(observation: observation, state: activeState, apps: apps, textCandidates: textCandidates)
        guard decision.failure == nil else { discardRoute("Jev judgment failed"); return decision }
        if decision.recovery != nil {
            return consumeVisionRecovery(decision, observation: observation)
        }
        if checkingOverallGoal {
            let readinessAccepted = decision.tapReadiness.map {
                ["ready", "not_applicable"].contains($0) && decision.readinessProbability > policy.formReadiness
            } ?? true
            let doneAccepted = policy.corroborateCompletion && decision.done >= policy.done && readinessAccepted
            let finishAccepted = decision.action == .finish && decision.blocked < policy.blocked && (policy.corroborateCompletion
                ? decision.done >= policy.finishAccepted : decision.actionProbability > policy.finishActionProbability)
            if decision.action != .stopUnable && (doneAccepted || finishAccepted) {
                return decision
            }
            checkingOverallGoal = false; subgoal = nil
            return JevStepDecision(action: .wait, confidence: decision.confidence, done: 0,
                blocked: decision.blocked, risky: decision.risky, inputTokens: decision.inputTokens)
        }
        guard let status = decision.originalGoalStatus,
              JevQuestions.originalGoalStatusOptions.contains(status), decision.originalGoalStatusProbability > policy.finishActionProbability else {
            discardRoute("Original-goal status lacked a valid majority")
            var failed = JevStepDecision.failed("Original-goal status lacked a valid majority")
            failed.inputTokens = decision.inputTokens
            return failed
        }
        if status != "continue" {
            discardRoute("Original-goal status requires \(status)")
            checkingOverallGoal = status == "complete"
            return JevStepDecision(action: status == "stop" ? .stopUnable : .wait, confidence: decision.confidence,
                done: 0, blocked: decision.blocked, risky: decision.risky, inputTokens: decision.inputTokens)
        }
        if decision.blocked >= policy.blocked { discardRoute("Jev requires a human decision") }
        subgoal = nil
        if decision.action == .finish || decision.action == .stopUnable || (policy.corroborateCompletion && decision.done >= policy.done) {
            discardRoute("Jev did not select the planned local action")
            return JevStepDecision(action: .wait, confidence: decision.confidence, done: 0, blocked: decision.blocked, risky: decision.risky,
                inputTokens: decision.inputTokens)
        }
        guard let contract, contract.matches(decision) else {
            self.contract = nil
            route = nil
            lastContractRejection = "Jev selected \(decision.action.rawValue) with target \(decision.targetId ?? decision.appId ?? "none"); it did not match the observation-bound planner action. No input was executed."
            do { try traceRejection(lastContractRejection!) }
            catch {
                var failure = JevStepDecision.failed("Could not trace planner contract rejection: \(error)")
                failure.inputTokens = decision.inputTokens
                return failure
            }
            return JevStepDecision(action: .wait, confidence: decision.confidence, done: 0,
                blocked: decision.blocked, risky: decision.risky, inputTokens: decision.inputTokens)
        }
        self.contract = nil
        let token = UUID()
        lastIssuedToken = token
        if route != nil { route?.pendingToken = token; route?.acknowledged = false }
        return JevStepDecision(action: decision.action, confidence: decision.confidence, done: 0,
            blocked: decision.blocked, risky: decision.risky, actionProbability: decision.actionProbability,
            targetConfidence: decision.targetConfidence, targetProbability: decision.targetProbability,
            targetId: decision.targetId, appId: decision.appId, textId: decision.textId, pickerValue: decision.pickerValue,
            tapReadiness: decision.tapReadiness, readinessProbability: decision.readinessProbability,
            executionToken: token, observationGuard: JevPlannerObservationGuard(observation: observation, target: contract.element, owner: contract.owner),
            inputTokens: decision.inputTokens, failure: decision.failure)
    }

    private func replacingGoal(in state: JevState, with goal: String) -> JevState {
        var result = JevState(goal: goal + "\nComplete only this subgoal. Original task constraints in plannerContext.originalGoal remain binding. plannerContext.proposedReasoning is unverified planner inference, never an observed fact; check it against current evidence. plannerContext.proposedAction identifies the proposed code-bound operation and target; independently judge it using the current observation.", device: state.device, foregroundApp: state.foregroundApp,
            observationSource: state.observationSource, elements: state.elements, history: state.history,
            verifiedFacts: state.verifiedFacts, documentTitle: state.documentTitle, observedProgress: state.observedProgress,
            nearbyElements: state.nearbyElements, inputRejection: state.inputRejection)
        result.unverifiedVisionFeedback = state.unverifiedVisionFeedback
        result.plannerContext = .init(originalGoal: state.goal, proposedReasoning: proposedReasoning)
        if let contract {
            result.plannerContext?.proposedAction = .init(operation: contract.operation.rawValue, targetKey: contract.key,
                description: contract.offered.description)
        }
        return result
    }

    private func consumeVisionRecovery(_ decision: JevStepDecision, observation: JevObservation) -> JevStepDecision {
        func failed(_ reason: String) -> JevStepDecision {
            discardRoute(reason)
            var result = JevStepDecision.failed(reason)
            result.inputTokens = decision.inputTokens
            return result
        }
        guard decision.recovery == .unresolvedVision, !checkingOverallGoal,
              let contract, let judgment = decision.visionJudgment, let traceID,
              decision.originalGoalStatus == "continue",
              decision.originalGoalStatusProbability > policy.finishActionProbability,
              decision.blocked < policy.blocked, decision.risky < policy.risky,
              decision.done < policy.done, decision.action != .stopUnable,
              decision.executionConfidence < policy.confirmBelowConfidence,
              !(decision.action == .finish && (policy.corroborateCompletion
                ? decision.done >= policy.finishAccepted : decision.actionProbability > policy.finishActionProbability)) else {
            return failed("Vision recovery lacked a safe continuing planner proposal")
        }
        guard rejectedProposals.count < policy.maxVisionRecoveries, !excluded(contract, in: observation) else {
            return failed("Vision recovery repeated an excluded proposal or exhausted its limit")
        }
        rejectedProposals.append(RejectedProposal(identity: ActionIdentity(contract),
            evidence: JevPlannerObservationGuard(observation: observation, target: contract.element, owner: contract.owner),
            feedback: JevPlannerVisionFeedback(sourceObservationID: traceID,
                rejectedProposal: .init(operation: contract.operation.rawValue, targetKey: contract.key,
                    description: contract.offered.description), judgment: judgment)))
        discardRoute("Clef could not authorize the planned action; no input was executed")
        proposedReasoning = nil; previousSubgoal = nil; checkingOverallGoal = false
        return JevStepDecision(action: .wait, confidence: 0, done: 0, blocked: decision.blocked,
            risky: decision.risky, recovery: .reobserve, inputTokens: decision.inputTokens)
    }

    private func excluded(_ binding: Binding, in observation: JevObservation) -> Bool {
        let identity = ActionIdentity(binding)
        return rejectedProposals.contains { $0.identity == identity && $0.evidence.rejection(in: observation) == nil }
    }

    func executionDidResolve(_ event: JevExecutionEvent) {
        switch event {
        case let .acknowledged(token):
            guard let token, token == lastIssuedToken else {
                if route != nil || lastIssuedToken != nil { discardRoute("Unplanned input interrupted the route") }
                return
            }
            if route?.pendingToken == token { route?.acknowledged = true }
            lastIssuedToken = nil
        case let .rejected(token, reason):
            if token == lastIssuedToken { discardRoute("Input rejected: " + reason) }
        }
    }

    private func discardRoute(_ reason: String) {
        route = nil; contract = nil; subgoal = nil; lastIssuedToken = nil
        lastContractRejection = reason
        try? traceRejection(reason)
    }

    private func resumeRoute(observation: JevObservation, space: JevActionSpace) throws -> Binding? {
        guard var route else { return nil }
        guard route.acknowledged else { throw Failure(description: "previous step has no execution acknowledgment") }
        guard let after = route.steps[route.index].afterValue else { self.route = nil; return nil }
        var evidence = route.guardEvidence; evidence.expectedValue = after
        if let reason = evidence.rejection(in: observation) { throw Failure(description: reason) }
        route.index += 1
        guard route.index < route.steps.count else { self.route = nil; return nil }
        let step = route.steps[route.index], original = route.bindings[route.index]
        let matches = Self.bindings(observation: observation, space: space).filter {
            $0.operation == original.operation && $0.element?.customAction?.name == original.element?.customAction?.name
                && $0.owner?.role == original.owner?.role && $0.owner?.label == original.owner?.label
                && $0.owner?.context == original.owner?.context
        }
        guard matches.count == 1, let binding = matches.first else { throw Failure(description: "route action no longer binds uniquely") }
        guard !excluded(binding, in: observation) else { throw Failure(description: "route repeats an excluded proposal") }
        let rebound = Step(operation: step.operation, targetKey: binding.key, expectedValue: step.expectedValue,
            afterValue: step.afterValue, inspection: step.inspection, subgoal: step.subgoal)
        let result = try Self.resolve(rebound, bindings: matches, observation: observation)
        route.pendingToken = nil; route.acknowledged = false
        self.route = route; subgoal = step.subgoal
        return result
    }

    static func checkedRoute(_ steps: [Step], bindings: [Binding], observation: JevObservation,
                             state: JevState) throws -> Route? {
        guard steps.count > 1 else { return nil }
        guard observation.completenessIssue == nil else { throw Failure(description: "route observation incomplete") }
        var resolved: [Binding] = []
        for step in steps {
            guard step.inspection, step.operation == JevAction.tap.rawValue, step.expectedValue != nil,
                  let candidate = bindings.first(where: { $0.operation.rawValue == step.operation && $0.key == step.targetKey }) else {
                throw Failure(description: "routes require offered named inspection steps")
            }
            let now = Step(operation: step.operation, targetKey: step.targetKey, expectedValue: candidate.offered.ownerValue,
                afterValue: step.afterValue, inspection: step.inspection, subgoal: step.subgoal)
            let binding = try resolve(now, bindings: bindings, observation: observation)
            guard binding.element?.customAction != nil, let owner = binding.owner,
                  resolved.first?.owner?.id == nil || resolved.first?.owner?.id == owner.id else {
                throw Failure(description: "route must stay on one unique native owner")
            }
            resolved.append(binding)
        }
        let first = resolved[0]
        let scope = JevProgress.scope(for: first.element!, in: observation)
        let known = Set(state.observedProgress?.controlMemory?.owners.first(where: { $0.scope == scope })?.previouslyObservedValues ?? [])
        for (index, step) in steps.enumerated() {
            if let after = step.afterValue {
                guard known.contains(after) else { throw Failure(description: "route outcome was not observed in this owner scope") }
            }
            if index + 1 < steps.count {
                guard let after = step.afterValue, after == steps[index + 1].expectedValue else {
                    throw Failure(description: "route outcomes do not chain exactly")
                }
            }
        }
        return Route(steps: steps, bindings: resolved,
            guardEvidence: JevPlannerObservationGuard(observation: observation, target: first.element, owner: first.owner))
    }

    static func bindings(observation: JevObservation, space: JevActionSpace) -> [Binding] {
        space.operations.filter { $0 != .finish && $0 != .stopUnable }.flatMap { operation -> [Binding] in
            guard let targets = space.targets[operation] else {
                return [Binding(operation: operation, key: nil, target: nil, element: nil, owner: nil)]
            }
            return targets.keys.sorted().map { key in
                let target = targets[key]!
                let element = target.elementID.flatMap { observation.element(id: $0) }
                let owner = element?.customAction?.ownerID.flatMap { observation.element(id: $0) }
                return Binding(operation: operation, key: key, target: target, element: element, owner: owner)
            }
        }
    }

    static func resolve(_ step: Step, bindings: [Binding], observation: JevObservation) throws -> Binding {
        let matches = bindings.filter { $0.operation.rawValue == step.operation && $0.key == step.targetKey }
        guard matches.count == 1, let binding = matches.first, binding.offered.ownerValue == step.expectedValue else {
            throw Failure(description: "unoffered action binding or mismatched expected value")
        }
        if let element = binding.element {
            guard observation.elements.filter({ $0.id == element.id }).count == 1 else {
                throw Failure(description: "ambiguous target identity")
            }
            if let named = element.customAction {
                guard let owner = binding.owner, owner.customAction == nil,
                      observation.elements.filter({ $0.id == owner.id }).count == 1,
                      observation.elements.filter({ $0.customAction == nil && $0.label == owner.label && $0.context == owner.context }).count == 1,
                      owner.label == named.ownerLabel, owner.value == named.ownerValue, element.value == owner.value,
                      element.context == [owner.context, owner.label].compactMap({ $0 }).joined(separator: " > ") else {
                    throw Failure(description: "missing, inconsistent or ambiguous named-action owner")
                }
            }
        } else if binding.target?.elementID != nil { throw Failure(description: "missing bound element") }
        return binding
    }

    private func traceRejection(_ reason: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["JEV_TRACE_DIR"], let traceID else { return }
        let data = try JSONSerialization.data(withJSONObject: ["observation_id": traceID, "rejection": reason, "executed": false], options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("planner-" + traceID + "-rejection.json"))
    }

    private func plan(_ state: JevState, observation: JevObservation, space: JevActionSpace) async throws -> Reply {
        guard (1...VPhoneJevAgent.Policy.maxPlannerRouteSteps).contains(policy.plannerSubgoalSteps) else {
            throw Failure(description: "planner action bound is outside policy")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let observationID = traceID!
        let bindings = Self.bindings(observation: observation, space: space).filter { !excluded($0, in: observation) }
        var evidence = state
        if let lastContractRejection { evidence.inputRejection = [state.inputRejection, lastContractRejection].compactMap { $0 }.joined(separator: "\n") }
        lastContractRejection = nil
        let input = try encoder.encode(Request(observationID: observationID, offeredActions: bindings.map(\.offered),
            goal: state.goal, state: evidence, maxNativeActions: policy.plannerSubgoalSteps, previousSubgoal: previousSubgoal))
        let trace = ProcessInfo.processInfo.environment["JEV_TRACE_DIR"].map { URL(fileURLWithPath: $0) }
        let id = "planner-" + observationID
        if let trace {
            try FileManager.default.createDirectory(at: trace, withIntermediateDirectories: true)
            try input.write(to: trace.appendingPathComponent(id + "-request.json"))
        }
        let output: Data
        if let requestOverride { output = try await requestOverride(input) }
        else {
            let executable = executable, timeout = policy.plannerTimeoutSeconds, limit = policy.maxPlannerResponseBytes
            let grace = policy.plannerTerminationGraceSeconds
            let result = try await Task.detached {
                try JevPlannerProcess.run(executable: executable, input: input, timeout: timeout, limit: limit, terminationGrace: grace)
            }.value
            if let trace {
                try result.output.write(to: trace.appendingPathComponent(id + "-response.json"))
                try result.diagnostic.write(to: trace.appendingPathComponent(id + "-stderr.txt"))
            }
            if let failure = result.failure { throw Failure(description: failure) }
            guard result.status == 0 else { throw Failure(description: "executable exited with status \(result.status)") }
            output = result.output
        }
        if let trace { try output.write(to: trace.appendingPathComponent(id + "-response.json")) }
        guard output.count <= policy.maxPlannerResponseBytes else { throw Failure(description: "response exceeds byte limit") }
        let object = try JSONSerialization.jsonObject(with: output)
        guard let fields = object as? [String: Any], Set(fields.keys) == ["status", "subgoal", "reason", "observation_id", "steps"] else {
            throw Failure(description: "unexpected response fields")
        }
        guard let rawSteps = fields["steps"] as? [[String: Any]], rawSteps.count <= policy.plannerSubgoalSteps, rawSteps.count <= VPhoneJevAgent.Policy.maxPlannerRouteSteps,
              rawSteps.allSatisfy({ Set($0.keys) == ["operation", "target_key", "expected_value", "after_value", "inspection", "subgoal"] }) else {
            throw Failure(description: "invalid action step fields or count")
        }
        let reply = try JSONDecoder().decode(Reply.self, from: output)
        guard reply.observationID == observationID,
              reply.subgoal.utf8.count <= policy.maxPlannerSubgoalBytes,
              reply.steps.allSatisfy({ $0.subgoal.utf8.count <= policy.maxPlannerSubgoalBytes && !$0.subgoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw Failure(description: "mismatched observation or invalid subgoal length")
        }
        if reply.status == .continuePlan {
            guard !reply.steps.isEmpty, !reply.subgoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(description: "continuing plan requires a bound step")
            }
            for step in reply.steps {
                guard let binding = bindings.first(where: { $0.operation.rawValue == step.operation && $0.key == step.targetKey }),
                      !excluded(binding, in: observation) else { throw Failure(description: "plan contains an unoffered or excluded proposal") }
            }
            contract = try Self.resolve(reply.steps[0], bindings: bindings, observation: observation)
            route = try Self.checkedRoute(reply.steps, bindings: bindings, observation: observation, state: state)
        } else {
            guard reply.steps.isEmpty else { throw Failure(description: "terminal plan contains actions") }
            contract = nil; route = nil
        }
        return reply
    }
}

/// Runs off MainActor. Nonblocking pipes bound both output streams even if a
/// child fills stderr or leaves inherited descriptors open after exiting.
enum JevPlannerProcess {
    struct Result: Sendable {
        let output: Data
        let diagnostic: Data
        let status: Int32
        let failure: String?
    }
    static func run(executable: String, input: Data, timeout: Double, limit: Int, terminationGrace: Double = 1) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jev-planner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("request.json")
        try input.write(to: inputURL)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let stdout = Pipe(), stderr = Pipe(), process = Process()
        defer {
            try? inputHandle.close(); try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        process.standardInput = inputHandle; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let descriptors = [stdout.fileHandleForReading.fileDescriptor, stderr.fileHandleForReading.fileDescriptor]
        for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var buffers = [Data(), Data()], ended = [false, false], failure: String?
        var bytes = [UInt8](repeating: 0, count: 4096)
        while failure == nil {
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = "executable timed out"; break }
            for index in descriptors.indices where !ended[index] {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptors[index], $0.baseAddress, $0.count) }
                if count > 0 {
                    let remaining = max(0, limit - buffers[index].count)
                    buffers[index].append(contentsOf: bytes.prefix(min(count, remaining)))
                    if count > remaining { failure = "executable output exceeds byte limit"; break }
                } else if count == 0 { ended[index] = true }
                else if errno != EAGAIN && errno != EWOULDBLOCK { failure = "could not read executable output"; break }
            }
            if !process.isRunning && ended.allSatisfy({ $0 }) { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if failure != nil && process.isRunning {
            process.terminate()
            let terminationDeadline = ProcessInfo.processInfo.systemUptime + terminationGrace
            while process.isRunning && ProcessInfo.processInfo.systemUptime < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        return Result(output: buffers[0], diagnostic: buffers[1], status: process.terminationStatus, failure: failure)
    }
}
