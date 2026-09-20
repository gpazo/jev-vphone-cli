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

        The VM must already be booted — this talks to it over the automation
        socket that `make boot` creates next to the VM config.

        Requires a TypeSafe API key in TYPESAFE_API_KEY, or --api-key.

        Examples:
          vphone-cli jev "turn on airplane mode"
          vphone-cli jev "open Safari and search for climate news" --dry-run
          vphone-cli jev "set the wallpaper to the second one" --yes
        """
    )

    @Argument(help: "What the phone should accomplish, in plain language.")
    var goal: String

    @Option(help: "Automation socket of the running VM.")
    var socket: String = "vm/vphone.sock"

    @Option(
        help: """
        Drive a booted iOS Simulator device by UDID instead of the vphone VM.         Observation is OCR over `simctl io screenshot`; taps are synthetic events,         so the host terminal needs Accessibility permission.
        """
    )
    var simulator: String?

    @Flag(help: "Decide and report every step without touching the phone.")
    var dryRun = false

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

    @Flag(
        help: """
        Ablation: run the identical loop with the judgment replaced by label         matching and no model calls. Everything else — observation, gates,         freshness checks, actuation — is unchanged, so a difference in outcome         is attributable to the judgment alone.
        """
    )
    var baseline = false

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
        let decider: any JevDecider = baseline
            ? JevBaselineDecider(goal: goal)
            : JevModelDecider(client: try VPhoneJevClient(apiKey: apiKey, model: model))

        let observer: any JevObservationProvider
        let liveActuator: any JevActuator
        var apps: [(bundleId: String, name: String)] = []
        var factProvider: (any JevFactProvider)?
        var keyboardTypist: JevKeyboardTypist?

        if let simulator {
            let simObserver = JevSimulatorObserver(udid: simulator)
            observer = simObserver
            apps = simObserver.installedApps()
            liveActuator = JevSimulatorActuator(udid: simulator)
            factProvider = JevSimulatorFacts(udid: simulator)
            // Synthetic key events do not reach the Simulator, so text is
            // entered by tapping the keys the way a person would.
            let simActuator = JevSimulatorActuator(udid: simulator)
            keyboardTypist = JevKeyboardTypist(
                observe: { try await simObserver.observe() },
                tap: { point in try await simActuator.tap(at: point) }
            )
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

        let actuator: any JevActuator = dryRun ? JevDryRunActuator() : liveActuator

        var policy = VPhoneJevAgent.Policy.default
        policy.maxSteps = maxSteps

        let agent = VPhoneJevAgent(
            goal: goal,
            decider: decider,
            provider: observer,
            actuator: actuator,
            policy: policy,
            mode: dryRun ? .dryRun : (yes ? .unattended : .live)
        )
        agent.installedApps = apps
        agent.facts = factProvider
        agent.typist = keyboardTypist
        agent.confirm = Self.confirmOnStdin
        agent.onStep = { step in Self.print(step, verbose: verbose) }

        header(probe, appCount: agent.installedApps.count, policy: decider.name)

        let outcome = try await agent.run()
        footer(outcome, tokens: agent.totalInputTokens)

        if case .stopped = outcome {
            throw ExitCode(1)
        }
    }

    // MARK: Output

    private func header(_ observation: JevObservation, appCount: Int, policy: String) {
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
