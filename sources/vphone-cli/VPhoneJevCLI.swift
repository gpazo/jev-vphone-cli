import ArgumentParser
import CoreGraphics
import Foundation

extension VPhoneJevClient.Provider: ExpressibleByArgument {}

// MARK: - jev

struct VPhoneJevCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jev",
        abstract: "Drive a running virtual iPhone toward a goal stated in plain language",
        discussion: """
        Observes the phone's accessibility tree as text, asks the selected
        decision model for one bounded action, executes it, and repeats.

        The target must already be booted. Use --simulator <udid> for an iOS
        Simulator, or the automation socket that `make boot` creates for a VM.

        Defaults to TypeSafe using TYPESAFE_API_KEY. For Clef, select
        --provider cloudflare and set CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN.

        Examples:
          vphone-cli jev "turn on airplane mode"
          vphone-cli jev "turn on Bold Text" --simulator booted
          vphone-cli jev "open Safari and search for climate news" --dry-run
          vphone-cli jev "set the wallpaper to the second one" --yes
        """
    )

    @Argument(help: "What the phone should accomplish, in plain language.")
    var goal: String = ""

    @Option(help: "Automation socket of the running VM.")
    var socket: String = "vm/vphone.sock"

    @Option(
        help: """
        Drive a booted iOS Simulator by UDID (or booted) using its accessibility
        tree and native HID input. Requires AXe; run make setup_jev first.
        """
    )
    var simulator: String?

    @Flag(help: "Decide and report every step without touching the phone.")
    var dryRun = false

    @Flag(help: "Keep the simulator and Jev connections ready; read one goal per stdin line until EOF.")
    var session = false

    @Flag(help: "With --session, read JSON lines containing id and goal; emit ready, result, and rejected events on stdout.")
    var sessionJson = false

    @Flag(name: .shortAndLong, help: "Act without asking, including on risky steps.")
    var yes = false

    @Option(help: "Give up after this many steps.")
    var maxSteps: Int = 25

    @Option(help: "Decision provider: typesafe or cloudflare (experimental).")
    var provider: VPhoneJevClient.Provider = .typesafe

    @Option(help: "API key for the selected provider; defaults to its environment variable.")
    var apiKey: String?

    @Option(help: "Model identifier; defaults to jev-latest for TypeSafe or clef for Cloudflare. Cloudflare also supports clef-flash.")
    var model: String?

    @Option(help: "Cloudflare account ID. Defaults to $CLOUDFLARE_ACCOUNT_ID.")
    var cloudflareAccountId: String?

    @Flag(help: "Experiment: Jev judges accessibility first; use one budgeted Clef screenshot fallback only below action/target confidence 0.85. Simulator only.")
    var clefVisionFallback = false

    @Flag(name: .shortAndLong, help: "Print the full state sent to Jev each step.")
    var verbose = false

    @Flag(help: "Print wall-clock stage timings, including the complete Jev request, in milliseconds.")
    var profile = false

    @Flag(help: "Discover and invoke named native accessibility actions (experimental simulator capability).")
    var customActions = false

    @Flag(help: "Experiment: use the terminal operation's majority probability instead of the independent done estimate; also offer stop_unable.")
    var terminalChoiceCompletion = false

    @Flag(help: "Experiment: validate each selected tap's form readiness with a bound Jev judgment.")
    var validateForms = false

    @Flag(help: "Experiment: shorter operation/target instructions; identical state, choices and validation gates.")
    var compactRequests = false

    @Flag(help: "Experiment: goal-focused operation/tap instructions when native named actions are present; identical state, choices and gates.")
    var focusedRequests = false

    @Flag(help: "Experiment: retain bounded historical values of native named-action owners from this run.")
    var rememberControls = false

    @Option(help: "Optional external JSON planner executable; Jev still selects and validates each native action.")
    var planner: String?

    @Flag(help: "Decompose a compound goal using the bundled guarded Codex planner (requires Codex login).")
    var decompose = false

    @Option(help: "Maximum checked native inspection steps per planner response (1...6); requires --planner or --decompose above 1.")
    var plannerMaxActions = 1

    @Flag(
        help: """
        Ablation: run the identical loop with the judgment replaced by label         matching and no model calls. Everything else — observation, gates,         freshness checks, actuation — is unchanged, so a difference in outcome         is attributable to the judgment alone.
        """
    )
    var baseline = false

    func validate() throws {
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session {
            throw ValidationError("Provide a goal, or use --session to read goals from stdin.")
        }
        if sessionJson && (!session || !goal.isEmpty) {
            throw ValidationError("--session-json requires --session and goals supplied as JSON lines on stdin.")
        }
        if decompose && planner != nil {
            throw ValidationError("Choose either --decompose or --planner.")
        }
        guard maxSteps > 0 else {
            throw ValidationError("--max-steps must be greater than zero.")
        }
        if compactRequests && focusedRequests {
            throw ValidationError("Choose only one request experiment: --compact-requests or --focused-requests.")
        }
        guard (1...VPhoneJevAgent.Policy.maxPlannerRouteSteps).contains(plannerMaxActions), plannerMaxActions == 1 || planner != nil || decompose else {
            throw ValidationError("--planner-max-actions must be 1...6 and requires --planner or --decompose above 1.")
        }
        if (planner != nil || decompose) && baseline {
            throw ValidationError("--planner and --decompose cannot be combined with --baseline.")
        }
        if clefVisionFallback && (provider != .typesafe || baseline || simulator == nil || validateForms) {
            throw ValidationError("--clef-vision-fallback requires TypeSafe/Jev, a simulator, and no --baseline or --validate-forms.")
        }
    }

    // MARK: Run

    func run() throws {
        // The agent is main-actor isolated, so the main thread must stay free
        // to service it. Drive the run loop and stop it when the task ends
        // rather than blocking on a semaphore, which would deadlock.
        let box = ErrorBox()
        let options = self

        Task { @MainActor in
            defer { CFRunLoopStop(CFRunLoopGetMain()) }
            do {
                try await options.execute()
            } catch {
                box.error = error
            }
        }

        CFRunLoopRun()

        // Rethrown as-is: a ValidationError would make ArgumentParser append
        // usage text to what is a runtime failure, not a usage mistake.
        if let error = box.error {
            throw error
        }
    }

    private final class ErrorBox: @unchecked Sendable {
        var error: Error?
    }

    @MainActor
    private func execute() async throws {
        let setupStarted = ProcessInfo.processInfo.systemUptime
        let plannerPath: String? = if decompose { try Self.bundledPlannerPath() } else { planner }
        let jsonOutput: FileHandle?
        if sessionJson {
            fflush(stdout)
            let descriptor = dup(STDOUT_FILENO)
            guard descriptor >= 0 else { throw ValidationError("Could not open session output.") }
            jsonOutput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
                throw ValidationError("Could not redirect session diagnostics.")
            }
        } else { jsonOutput = nil }
        defer {
            if let jsonOutput { fflush(stdout); _ = dup2(jsonOutput.fileDescriptor, STDOUT_FILENO) }
        }
        func emit(_ event: JevSessionEvent) throws {
            guard let jsonOutput else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event)
            data.append(0x0A)
            try jsonOutput.write(contentsOf: data)
        }
        let client = baseline ? nil : try VPhoneJevClient(apiKey: apiKey, model: model,
            provider: provider, accountID: cloudflareAccountId)
        let visionClient = clefVisionFallback ? try VPhoneJevClient(model: "clef", provider: .cloudflare,
            accountID: cloudflareAccountId) : nil
        let visionHelper = FileManager.default.currentDirectoryPath + "/tests/DecisionReplay/clef_fallback.zsh"
        if clefVisionFallback && !FileManager.default.isExecutableFile(atPath: visionHelper) {
            throw ValidationError("Run --clef-vision-fallback from the repository root with its Python environment installed.")
        }
        let observer: any JevObservationProvider
        let liveActuator: any JevActuator
        var apps: [(bundleId: String, name: String)] = []
        let factProvider: (any JevFactProvider)? = nil
        var simulatorBridge: JevSimulatorBridge?
        var preferences: JevSimulatorPreferences?
        defer { preferences?.stop() }
        defer { simulatorBridge?.stop() }

        if let simulator {
            let bridge = try JevSimulatorBridge(udid: simulator)
            bridge.inspectCustomActions = customActions
            if profile {
                bridge.onObservationTiming = { tree, decode, hits, count, retry, snapshot in
                    Swift.print(String(format: "  observation tree %.1f ms decode %.1f ms hit-tests %.1f ms (%d) retry %d snapshot %@",
                        tree * 1000, decode * 1000, hits * 1000, count, retry, snapshot ? "yes" : "no"))
                }
            }
            simulatorBridge = bridge
            let simObserver = JevSimulatorObserver(bridge: bridge)
            observer = simObserver
            apps = simObserver.installedApps()
            liveActuator = JevSimulatorActuator(bridge: bridge)
            preferences = try JevSimulatorPreferences(udid: bridge.udid,
                helper: bridge.executable.deletingLastPathComponent().appendingPathComponent("JevSimulatorPreferences"))
            bridge.services = preferences
            // App storage is an evaluation oracle, not general controller input.
        } else {
            let socketClient = VPhoneJevSocketClient(socketPath: socket)
            let socketObserver = JevSocketObserver(client: socketClient)
            observer = socketObserver
            apps = socketObserver.installedApps()
            liveActuator = JevSocketActuator(
                client: socketClient,
                screen: try await socketObserver.observe().screen
            )
        }

        // One probe up front: fails fast with a useful message if the target
        // is not running, rather than after the first API call is billed.
        let probe = try await observer.observe()
        let setupSeconds = ProcessInfo.processInfo.systemUptime - setupStarted

        let actuator: any JevActuator = dryRun ? JevDryRunActuator() : liveActuator

        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = maxSteps
        policy.plannerSubgoalSteps = plannerMaxActions
        policy.corroborateCompletion = !terminalChoiceCompletion
        if simulator != nil {
            policy.settlePollMilliseconds = 30
            policy.settleQuietMilliseconds = 150
        }

        var requests = JevSessionRequests()
        var pendingGoal: String? = goal.isEmpty ? nil : goal
        if session {
            // Start every guest service before announcing readiness. No goal
            // action or model decision is performed during this preparation.
            _ = await factProvider?.snapshot()
            try preferences?.prepareActions()
            await client?.prepareConnection()
            Swift.print(String(format: "  ready     setup %.3f seconds; enter a goal per line", ProcessInfo.processInfo.systemUptime - setupStarted))
            fflush(stdout)
            try emit(.init(event: "ready", elapsedSeconds: ProcessInfo.processInfo.systemUptime - setupStarted))
        }
        while true {
            var requestID: String?
            let currentGoal: String
            if let pendingGoal { currentGoal = pendingGoal }
            else {
                guard let line = readLine() else { break }
                if sessionJson {
                    switch requests.accept(line) {
                    case let .goal(request): currentGoal = request.goal; requestID = request.id
                    case let .rejected(id, reason):
                        try emit(.init(event: "rejected", id: id, reason: reason))
                        continue
                    }
                } else {
                    if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    currentGoal = line
                }
            }
            let goalStarted = session ? ProcessInfo.processInfo.systemUptime : setupStarted
            var totals: [String: Double] = session ? [:] : ["setup and probe": setupSeconds]
            let baseDecider: any JevDecider = baseline
                ? JevBaselineDecider(goal: currentGoal)
                : JevModelDecider(client: client!, terminalChoiceCompletion: terminalChoiceCompletion,
                                  validateForms: validateForms, compactRequests: compactRequests,
                                  focusedRequests: focusedRequests)
            let groundedDecider: any JevDecider
            if let visionClient, let simulatorBridge {
                var secondary = JevModelDecider(client: visionClient, terminalChoiceCompletion: terminalChoiceCompletion,
                    compactRequests: compactRequests, focusedRequests: focusedRequests, includeVisionDiagnostic: true)
                let udid = simulatorBridge.udid
                secondary.requestOverride = { state, questions in
                    try await JevClefVisionTransport.ask(client: visionClient, state: state, questions: questions,
                        simulator: udid, executable: visionHelper)
                }
                groundedDecider = JevVisionFallbackDecider(primary: baseDecider, vision: secondary,
                    observer: observer, policy: policy)
            } else { groundedDecider = baseDecider }
            let decider: any JevDecider
            if let plannerPath {
                decider = JevPlannerDecider(base: groundedDecider,
                    executable: URL(fileURLWithPath: plannerPath).standardizedFileURL.path, policy: policy)
            } else { decider = groundedDecider }
            let agent = VPhoneJevAgent(
                goal: currentGoal,
                decider: decider,
                provider: observer,
                actuator: actuator,
                policy: policy,
                mode: dryRun ? .dryRun : (yes ? .unattended : .live)
            )
            agent.installedApps = apps
            agent.rememberControls = rememberControls
            agent.facts = factProvider
            // A queued goal must never be consumed as a confirmation answer.
            if session { agent.confirm = { _ in false } }
            else { agent.confirm = Self.confirmOnStdin }
            agent.onStep = { step in Self.print(step, verbose: verbose) }
            agent.onAttempt = { index, detail in
                Swift.print("  attempt   \(index) \(detail)")
                fflush(stdout)
            }
            if profile {
                agent.onTiming = { step, stage, seconds in
                    totals[stage, default: 0] += seconds
                    Swift.print(String(format: "  timing step %d %@: %.1f ms", step, stage, seconds * 1000))
                }
            }
            if verbose {
                agent.onState = { state in
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    if let data = try? encoder.encode(state), let text = String(data: data, encoding: .utf8) {
                        Swift.print("  state     \(text)")
                    }
                }
            }

            let currentProbe: JevObservation
            do { currentProbe = session ? try await observer.observe() : probe }
            catch {
                try emit(.init(event: "result", id: requestID, goal: currentGoal, outcome: "failed",
                    reason: "Could not observe the phone: \(error)", elapsedSeconds: ProcessInfo.processInfo.systemUptime - goalStarted))
                throw error
            }
            header(currentProbe, goal: currentGoal, appCount: agent.installedApps.count, policy: decider.name)

            let outcome: VPhoneJevAgent.Outcome
            do { outcome = try await agent.run() }
            catch {
                guard session else { throw error }
                try emit(.init(event: "result", id: requestID, goal: currentGoal, outcome: "failed",
                    reason: String(describing: error), elapsedSeconds: ProcessInfo.processInfo.systemUptime - goalStarted,
                    inputTokens: agent.totalInputTokens))
                Swift.print("  failed    \(error)")
                pendingGoal = nil
                _ = try await observer.observe()
                continue
            }
            footer(outcome, tokens: agent.totalInputTokens)
            try emit(JevSessionEvent(id: requestID, goal: currentGoal, outcome: outcome,
                elapsedSeconds: ProcessInfo.processInfo.systemUptime - goalStarted,
                inputTokens: agent.totalInputTokens, completionAudit: agent.completionAudit))
            if verbose, let evidence = agent.completionAudit {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(evidence), let text = String(data: data, encoding: .utf8) {
                    Swift.print("  evidence  \(text)")
                }
            }

            if profile {
                for stage in totals.keys.sorted() {
                    Swift.print(String(format: "  timing total %@: %.1f ms", stage, totals[stage]! * 1000))
                }
            }
            Swift.print(String(format: "  elapsed   %.3f seconds", ProcessInfo.processInfo.systemUptime - goalStarted))
            fflush(stdout)
            if !session && !outcome.succeeded { throw ExitCode(1) }
            if !session { break }
            if !outcome.succeeded { _ = try await observer.observe() }
            pendingGoal = nil
        }
    }

    static func bundledPlannerPath(executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) throws -> String {
        var candidates: [URL] = []
        var parent = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(parent.appendingPathComponent("scripts/jev_codex_planner.py"))
            parent.deleteLastPathComponent()
        }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw ValidationError("--decompose could not find scripts/jev_codex_planner.py beside this checkout or executable. Use --planner with its explicit path.")
        }
        return path.standardizedFileURL.path
    }

    // MARK: Output

    private func header(_ observation: JevObservation, goal: String, appCount: Int, policy: String) {
        Swift.print("")
        Swift.print("  goal      \(goal)")
        Swift.print("  policy    \(policy)")
        Swift.print("  app       \(observation.foregroundApp)")
        Swift.print("  observing \(observation.source.rawValue) — \(observation.elements.count) elements, \(appCount) apps")
        Swift.print("  mode      \(dryRun ? "dry run (nothing will be touched)" : (yes ? "unattended" : "confirm when risky or uncertain"))")
        Swift.print("")
    }

    private static func print(_ step: VPhoneJevAgent.Step, verbose: Bool) {
        // `detail` already reads as a verb phrase ("tap \"Settings\"",
        // "scroll down"), so the action name is not repeated alongside it.
        let marker = step.executed ? "→" : "·"
        Swift.print(
            String(
                format: "  %@ %2d  %-44@ conf %.2f",
                marker, step.index, step.detail as NSString, step.actionConfidence
            )
        )
        if verbose {
            if let confidence = step.targetConfidence, let probability = step.targetProbability {
                Swift.print(String(format: "          target confidence %.2f   selected probability %.2f", confidence, probability))
            }
            Swift.print(
                String(
                    format: "          done %.2f   blocked %.2f   risky %.2f   %d tokens",
                    step.done, step.blocked, step.risky, step.inputTokens
                )
            )
        }
    }

    private func footer(_ outcome: VPhoneJevAgent.Outcome, tokens: Int) {
        Swift.print("")
        switch outcome {
        case let .achieved(steps):
            Swift.print("  done      goal reached in \(steps) step\(steps == 1 ? "" : "s")")
        case let .stopped(reason, steps):
            Swift.print("  stopped   \(reason) (after \(steps) step\(steps == 1 ? "" : "s"))")
        case let .exhausted(steps):
            Swift.print("  gave up   step budget of \(steps) exhausted")
        }
        Swift.print("  cost      \(tokens) input tokens")
        Swift.print("")
    }

    /// Ask on the terminal. Anything but an explicit yes stops the run.
    ///
    /// With no tty — piped, under `make`, in CI — there is nobody to answer,
    /// and blocking on `readLine` would hang forever. Decline instead, and
    /// say why.
    @MainActor
    private static func confirmOnStdin(_ prompt: String) async -> Bool {
        guard isatty(STDIN_FILENO) == 1 else {
            Swift.print("  confirm   \(prompt)")
            Swift.print("            no terminal to ask — declining. Re-run with --yes to act unattended.")
            return false
        }

        Swift.print("  confirm   \(prompt) [y/N] ", terminator: "")
        guard let answer = readLine(strippingNewline: true)?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }
}

// MARK: - Structured warm session

struct JevSessionRequests {
    struct Request: Decodable {
        let id: String
        let goal: String
    }
    enum Input {
        case goal(Request)
        case rejected(id: String?, reason: String)
    }
    private var acceptedIDs: Set<String> = []

    mutating func accept(_ line: String) -> Input {
        guard line.utf8.count <= 131_072 else { return .rejected(id: nil, reason: "Request exceeds 128 KiB.") }
        let data = Data(line.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .rejected(id: nil, reason: "Expected a JSON object with id and goal.")
        }
        let id = object["id"] as? String
        guard Set(object.keys) == ["id", "goal"], let request = try? JSONDecoder().decode(Request.self, from: data),
              !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.id.utf8.count <= 128,
              !request.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.goal.utf8.count <= 65_536 else {
            return .rejected(id: id, reason: "Expected a nonempty id (up to 128 bytes) and goal (up to 64 KiB).")
        }
        guard acceptedIDs.insert(request.id).inserted else {
            return .rejected(id: request.id, reason: "Duplicate id; the goal was not executed again.")
        }
        return .goal(request)
    }
}

struct JevSessionEvent: Encodable {
    let event: String
    var id: String? = nil
    var goal: String? = nil
    var outcome: String? = nil
    var reason: String? = nil
    var steps: Int? = nil
    var elapsedSeconds: Double? = nil
    var inputTokens: Int? = nil
    var completionAudit: VPhoneJevAgent.CompletionAudit? = nil
}

extension JevSessionEvent {
    init(id: String?, goal: String, outcome: VPhoneJevAgent.Outcome, elapsedSeconds: Double,
         inputTokens: Int, completionAudit: VPhoneJevAgent.CompletionAudit?) {
        self.init(event: "result", id: id, goal: goal, elapsedSeconds: elapsedSeconds,
            inputTokens: inputTokens, completionAudit: completionAudit)
        switch outcome {
        case let .achieved(steps): self.outcome = "achieved"; self.steps = steps
        case let .stopped(reason, steps): self.outcome = "stopped"; self.reason = reason; self.steps = steps
        case let .exhausted(steps): self.outcome = "exhausted"; self.steps = steps
        }
    }
}
