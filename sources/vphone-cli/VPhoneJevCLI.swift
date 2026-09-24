import ArgumentParser
import CoreGraphics
import Foundation

// MARK: - jev

struct VPhoneJevCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jev",
        abstract: "Drive a running virtual iPhone toward a goal stated in plain language",
        discussion: """
        Observes the phone's screen as text, asks Jev (TypeSafe's System One
        model) for one bounded action at a time, executes it, and repeats.

        The target must already be booted. Use --simulator <udid> for an iOS
        Simulator, or the automation socket that `make boot` creates for a VM.

        Requires a TypeSafe API key in TYPESAFE_API_KEY, or --api-key.

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

    @Flag(name: .shortAndLong, help: "Act without asking, including on risky steps.")
    var yes = false

    @Option(help: "Give up after this many steps.")
    var maxSteps: Int = 25

    @Option(help: "TypeSafe API key. Defaults to $TYPESAFE_API_KEY.")
    var apiKey: String?

    @Option(help: "TypeSafe model identifier.")
    var model: String = VPhoneJevClient.defaultModel

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
        guard maxSteps > 0 else {
            throw ValidationError("--max-steps must be greater than zero.")
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
        let client = baseline ? nil : try VPhoneJevClient(apiKey: apiKey, model: model)
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
        policy.corroborateCompletion = !terminalChoiceCompletion
        if simulator != nil { policy.settlePollMilliseconds = 30 }

        var pendingGoal: String? = goal.isEmpty ? nil : goal
        if session {
            // Start every guest service before announcing readiness. No goal
            // action or model decision is performed during this preparation.
            _ = await factProvider?.snapshot()
            try preferences?.prepareActions()
            await client?.prepareConnection()
            Swift.print(String(format: "  ready     setup %.3f seconds; enter a goal per line", ProcessInfo.processInfo.systemUptime - setupStarted))
            fflush(stdout)
        }
        while true {
            let currentGoal: String
            if let pendingGoal { currentGoal = pendingGoal }
            else {
                guard let line = readLine() else { break }
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                currentGoal = line
            }
            let goalStarted = session ? ProcessInfo.processInfo.systemUptime : setupStarted
            var totals: [String: Double] = session ? [:] : ["setup and probe": setupSeconds]
            let decider: any JevDecider = baseline
                ? JevBaselineDecider(goal: currentGoal)
                : JevModelDecider(client: client!, terminalChoiceCompletion: terminalChoiceCompletion,
                                  validateForms: validateForms, compactRequests: compactRequests)
            let agent = VPhoneJevAgent(
                goal: currentGoal,
                decider: decider,
                provider: observer,
                actuator: actuator,
                policy: policy,
                mode: dryRun ? .dryRun : (yes ? .unattended : .live)
            )
            agent.installedApps = apps
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

            header(probe, goal: currentGoal, appCount: agent.installedApps.count, policy: decider.name)

            let outcome = try await agent.run()
            footer(outcome, tokens: agent.totalInputTokens)

            if profile {
                for stage in totals.keys.sorted() {
                    Swift.print(String(format: "  timing total %@: %.1f ms", stage, totals[stage]! * 1000))
                }
            }
            Swift.print(String(format: "  elapsed   %.3f seconds", ProcessInfo.processInfo.systemUptime - goalStarted))
            fflush(stdout)
            if !session && !outcome.succeeded { throw ExitCode(1) }
            if !session { break }
            pendingGoal = nil
        }
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
