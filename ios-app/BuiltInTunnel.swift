//
//  BuiltInTunnel.swift
//  AirCard-iOS
//
//  Drives the embedded `TunnelProv` packet-tunnel extension so the app can reach
//  the device's own lockdownd / RSD / atc services without a separate VPN app.
//  Falls back gracefully when the Network Extension entitlement is unavailable
//  (e.g. free-account sideloads), in which case the existing external
//  LocalDevVPN / WireGuard detection still applies.
//

import Foundation
import NetworkExtension
import Combine

@MainActor
final class BuiltInTunnel: ObservableObject {

    static let shared = BuiltInTunnel()

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case disconnecting
        case failed(String)
        case unsupported

        var label: String {
            switch self {
            case .idle: return "Off"
            case .connecting: return "Connecting…"
            case .connected: return "On"
            case .disconnecting: return "Stopping…"
            case .failed(let message): return "Error: \(message)"
            case .unsupported: return "Unavailable"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var onDemandEnabled: Bool = false

    var isConnected: Bool { state == .connected }
    var isBusy: Bool { state == .connecting || state == .disconnecting }
    var isUnsupported: Bool { state == .unsupported }

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var didLoad = false

    private let tunnelBundleId: String

    private var ifaceIP: String {
        UserDefaults.standard.string(forKey: TunnelConstants.ifaceIPConfigurationKey)
            ?? TunnelConstants.defaultIfaceIP
    }
    private var peerIP: String {
        UserDefaults.standard.string(forKey: TunnelConstants.peerIPConfigurationKey)
            ?? TunnelConstants.defaultPeerIP
    }

    private init() {
        tunnelBundleId = (Bundle.main.bundleIdentifier ?? "com.mak5er.aircard") + ".TunnelProv"
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let connection = note.object as? NEVPNConnection,
                      connection == self.manager?.connection else { return }
                self.apply(connection.status)
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    // MARK: - Public API

    /// Loads any existing configuration so `state` reflects reality on launch.
    func refresh() async {
        await loadIfNeeded()
        if let manager {
            apply(manager.connection.status)
        }
    }

    /// Starts the tunnel if needed and waits for it to come up.
    /// Returns `true` when the loopback peer is reachable.
    @discardableResult
    func ensureConnected(timeout: TimeInterval = 25) async -> Bool {
        await loadIfNeeded()

        if isConnected { return true }
        if case .unsupported = state { return false }

        if !isBusy {
            await start()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isConnected { return true }
            if case .failed = state { return false }
            if case .unsupported = state { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isConnected
    }

    func start() async {
        await loadIfNeeded()

        if manager == nil {
            if case .unsupported = state { return }
            do {
                manager = try await createManager()
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }

        guard let manager else {
            if case .unsupported = state { return }
            state = .failed("Tunnel configuration unavailable")
            return
        }

        switch manager.connection.status {
        case .connected, .connecting:
            apply(manager.connection.status)
            return
        default:
            break
        }

        state = .connecting
        manager.isEnabled = true
        configureOnDemand(manager)

        do {
            try await save(manager)
            try await reload(manager)
            let options: [String: NSObject] = [
                TunnelConstants.ifaceIPConfigurationKey: ifaceIP as NSObject,
                TunnelConstants.peerIPConfigurationKey: peerIP as NSObject,
            ]
            try manager.connection.startVPNTunnel(options: options)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        guard let manager else { return }
        state = .disconnecting
        manager.connection.stopVPNTunnel()
    }

    /// Toggles the on-demand rule. When enabled, iOS may bring the tunnel up by
    /// itself for matching traffic; when disabled, only an explicit start does.
    func setOnDemand(_ enabled: Bool) {
        guard let manager else { return }
        if enabled {
            configureOnDemand(manager)
        } else {
            manager.onDemandRules = []
        }
        manager.isOnDemandEnabled = enabled
        manager.isEnabled = true
        onDemandEnabled = enabled
        Task {
            do {
                try await save(manager)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func toggle() async {
        if isConnected || isBusy {
            stop()
        } else {
            await start()
        }
    }

    // MARK: - Configuration

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true

        do {
            let managers = try await loadAll()
            if let existing = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelBundleId
            }) {
                manager = existing
                onDemandEnabled = existing.isOnDemandEnabled
                apply(existing.connection.status)
            }
        } catch {
            // Most commonly: missing Network Extension entitlement (free account).
            state = .unsupported
        }
    }

    private func createManager() async throws -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "AirCard Loopback Tunnel"

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleId
        proto.serverAddress = "AirCard Loopback Tunnel"
        proto.providerConfiguration = [
            TunnelConstants.ifaceIPConfigurationKey: ifaceIP,
            TunnelConstants.peerIPConfigurationKey: peerIP,
        ]
        manager.protocolConfiguration = proto

        configureOnDemand(manager)
        manager.isEnabled = true
        onDemandEnabled = true

        try await save(manager)
        try await reload(manager)
        return manager
    }

    private func configureOnDemand(_ manager: NETunnelProviderManager) {
        let rule = NEOnDemandRuleEvaluateConnection()
        rule.interfaceTypeMatch = .any
        rule.connectionRules = [NEEvaluateConnectionRule(
            matchDomains: [ifaceIP, peerIP],
            andAction: .connectIfNeeded
        )]
        manager.onDemandRules = [rule]
        manager.isOnDemandEnabled = true
    }

    private func apply(_ status: NEVPNStatus) {
        switch status {
        case .invalid, .disconnected:
            state = .idle
        case .connecting, .reasserting:
            state = .connecting
        case .connected:
            state = .connected
        case .disconnecting:
            state = .disconnecting
        @unknown default:
            state = .idle
        }
    }

    // MARK: - Async wrappers

    private func loadAll() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
