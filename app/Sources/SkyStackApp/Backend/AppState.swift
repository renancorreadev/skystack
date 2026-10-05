import SwiftUI
import AppKit

// AppState owns the live view of one selected host's resources, polled from the
// CLI. All mutation happens on the main actor so SwiftUI updates are safe.
@MainActor
final class AppState: ObservableObject {
    @Published var hosts: [Host] = []
    @Published var selectedHost: String = "skyvm"
    @Published var section: Section = .containers {
        didSet { if section != oldValue { Task { await refreshOthers() } } }
    }
    @Published var search = ""

    @Published var containers: [Container] = []
    @Published var images: [DockerImage] = []
    @Published var volumes: [Volume] = []
    @Published var networks: [DockerNetwork] = []
    @Published var machines: [Machine] = []

    @Published var containerSelection: String?
    @Published var imageSelection: String?
    @Published var volumeSelection: String?
    @Published var networkSelection: String?
    @Published var machineSelection: String?

    @Published var cliError: String?
    @Published var loaded = false
    @Published var busyIDs: Set<String> = []

    // ⌘K command palette + the remote-connect sheet, both triggerable globally
    // (the palette opens via a menu command, and offers "Connect to remote…").
    @Published var paletteOpen = false
    @Published var remoteSheetOpen = false

    // SkyVM lifecycle (Batch B) + per-host loading (Batch A) to avoid showing the
    // previous host's resources while the new host is still being fetched.
    @Published var vmStatus: VMStatus?
    @Published var vmBusy = false
    @Published var loadingResources = true

    let cli = SkyCLI()
    private var pollTask: Task<Void, Never>?
    private var hostInitialized = false
    private var tick = 0
    private var appActive = true

    var binaryMissing: Bool { cli.binaryPath == nil }

    init() {
        startHostsWatch()
        startPolling()
        // Back off polling when the app isn't focused — saves CPU and (over SSH)
        // remote round-trips while hidden.
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appActive = true }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.appActive = false }
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let ns = await self?.refreshAndInterval() else { break }
                try? await Task.sleep(nanoseconds: ns)
            }
        }
    }

    // One MainActor hop: refresh, then report how long to wait (longer when idle).
    private func refreshAndInterval() async -> UInt64 {
        await refresh()
        return appActive ? 2_000_000_000 : 20_000_000_000
    }

    func refresh() async {
        guard !binaryMissing else {
            cliError = SkyError.notFound.errorDescription
            return
        }
        // Hosts come from the persistent hosts-watch (warm, push-on-change);
        // containers from the per-host event-stream. Polling only backstops them and
        // covers the slow-moving resources. Most ticks therefore do ~nothing.
        if !hostsWatchOK, let hs = try? await cli.hosts() { applyHosts(hs) }
        let slow = (tick % 5 == 0) || !hostInitialized
        if slow {
            vmStatus = try? await cli.vmStatus()
        }
        ensureContainerWatch()
        if !containerWatchOK { await refreshContainers() }
        if slow { await refreshOthers() }
        tick &+= 1
        loaded = true
    }

    // MARK: hosts event-stream watch

    private var hostsWatchTask: Task<Void, Never>?
    private var hostsWatchCancel: (() -> Void)?
    private var hostsWatchOK = false

    private func startHostsWatch() {
        hostsWatchCancel?()
        hostsWatchTask?.cancel()
        let (stream, cancel) = cli.watchHosts()
        hostsWatchCancel = cancel
        hostsWatchTask = Task { [weak self] in
            for await hs in stream {
                guard let self else { break }
                self.hostsWatchOK = true
                self.applyHosts(hs)
            }
            if let self { self.hostsWatchOK = false }
        }
    }

    private func applyHosts(_ hs: [Host]) {
        hosts = hs
        cliError = nil
        if !hostInitialized, !hosts.isEmpty {
            selectedHost = hosts.first(where: { $0.name == "skyvm" && $0.up })?.name
                ?? hosts.first(where: { $0.up })?.name
                ?? hosts.first!.name
            hostInitialized = true
        }
    }

    // MARK: container event-stream watch

    private var watchHost: String?
    private var watchTask: Task<Void, Never>?
    private var watchCancel: (() -> Void)?
    private var containerWatchOK = false

    private var watchAttemptTick = -100
    private func ensureContainerWatch() {
        guard hostInitialized else { return }
        if watchHost == selectedHost, containerWatchOK { return }
        // Backoff: when a host is down the watch process exits fast; don't respawn
        // it every 2s tick — retry at most ~every 6s for the same host.
        if watchHost == selectedHost, tick - watchAttemptTick < 3 { return }
        watchAttemptTick = tick
        startContainerWatch()
    }

    private func startContainerWatch() {
        watchCancel?()
        watchTask?.cancel()
        let host = selectedHost
        watchHost = host
        containerWatchOK = false
        let (stream, cancel) = cli.watchContainers(host: host)
        watchCancel = cancel
        watchTask = Task { [weak self] in
            for await cs in stream {
                guard let self, self.selectedHost == host else { break }
                self.containerWatchOK = true
                self.applyContainers(cs)
            }
            if let self, self.watchHost == host { self.containerWatchOK = false }
        }
    }

    private func applyContainers(_ cs: [Container]) {
        containers = cs
        loadingResources = false
        if containerSelection == nil || !containers.contains(where: { $0.id == containerSelection }) {
            containerSelection = containers.first(where: { $0.isRunning })?.id ?? containers.first?.id
        }
    }

    // Full refresh (both tiers) — used on host switch and after mutating actions.
    func refreshResources() async {
        await refreshContainers()
        await refreshOthers()
    }

    func refreshContainers() async {
        let host = selectedHost
        let c = try? await cli.containers(host: host)
        guard host == selectedHost else { return }
        applyContainers(c ?? [])
    }

    func refreshOthers() async {
        let host = selectedHost
        async let i = try? cli.images(host: host)
        async let v = try? cli.volumes(host: host)
        async let n = try? cli.networks(host: host)
        async let m = try? cli.machines(host: host)
        let (ii, vv, nn, mm) = await (i, v, n, m)
        guard host == selectedHost else { return }
        images = ii ?? []
        volumes = vv ?? []
        networks = nn ?? []
        machines = mm ?? []
    }

    func selectHost(_ name: String) {
        guard name != selectedHost else { return }
        selectedHost = name
        containerSelection = nil
        imageSelection = nil
        volumeSelection = nil
        networkSelection = nil
        machineSelection = nil
        // Clear immediately + flag loading so the old host's rows don't linger.
        containers = []; images = []; volumes = []; networks = []; machines = []
        loadingResources = true
        startContainerWatch()              // re-point the event-stream at the new host
        Task { await refreshResources() }
    }

    // Drives the SkyVM lifecycle from the UI (Batch B). Boots can take ~10-20s;
    // vmBusy gates the control and shows a spinner until the engine answers.
    func vmAction(_ action: String) {
        guard !vmBusy else { return }
        vmBusy = true
        Task {
            _ = await cli.vmLifecycle(action)
            await refresh()
            vmBusy = false
        }
    }

    var selectedHostInfo: Host? { hosts.first { $0.name == selectedHost } }
    var selectedContainer: Container? { containers.first { $0.id == containerSelection } }
    var runningCount: Int { containers.filter(\.isRunning).count }

    // Reachability of the selected host. Assume reachable until the host-watch
    // proves otherwise, so we don't flash "offline" during the initial load.
    var selectedHostReachable: Bool { selectedHostInfo?.up ?? true }
    var selectedHostError: String? {
        guard let e = selectedHostInfo?.error, !e.isEmpty else { return nil }
        return e
    }
    // True once the selected host is known-unreachable and we're past loading —
    // the signal to swap an "empty" panel for an explicit "offline" panel.
    var hostOffline: Bool { !loadingResources && !selectedHostReachable }

    // A "Start SkyVM" action, offered in the offline panel only when the
    // unreachable host is the local SkyVM and it isn't already ready.
    var vmStartAction: (() -> Void)? {
        guard selectedHost == "skyvm", !(vmStatus?.ready ?? false) else { return nil }
        return { [weak self] in self?.vmAction("start") }
    }

    func count(_ s: Section) -> Int {
        switch s {
        case .containers: return containers.count
        case .images: return images.count
        case .volumes: return volumes.count
        case .networks: return networks.count
        case .machines: return machines.count
        case .commands, .hardware, .operatorAI: return 0
        }
    }

    func perform(_ action: String, on c: Container) {
        busyIDs.insert(c.id)
        Task {
            do { try await cli.action(action, ref: c.ref) }
            catch { cliError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            await refreshResources()
            busyIDs.remove(c.id)
        }
    }

    func isBusy(_ c: Container) -> Bool { busyIDs.contains(c.id) }

    // Lazily detected language/framework per container (id → brand key), used for
    // a real logo when the image/name don't reveal it. One inspect per container,
    // cached; only requested for containers without an image/name brand match.
    @Published var frameworks: [String: String] = [:]
    private var fwRequested: Set<String> = []
    func detectFramework(_ c: Container) {
        guard !fwRequested.contains(c.id) else { return }
        fwRequested.insert(c.id)
        Task {
            if let f = try? await cli.framework(ref: c.ref), !f.isEmpty {
                frameworks[c.id] = f
            }
        }
    }

    // Bulk lifecycle for a whole compose stack (one refresh at the end).
    func performAll(_ action: String, _ cs: [Container]) {
        let ids = cs.map(\.id)
        busyIDs.formUnion(ids)
        Task {
            for c in cs {
                do { try await cli.action(action, ref: c.ref) }
                catch { cliError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            }
            await refreshResources()
            busyIDs.subtract(ids)
        }
    }

    // Delete a container by its bare name (NOT the host/name ref).
    func deleteContainer(_ c: Container) {
        busyIDs.insert(c.id)
        Task {
            do { try await cli.remove(kind: "container", host: selectedHost, id: c.name) }
            catch { cliError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            await refreshResources()
            busyIDs.remove(c.id)
        }
    }

    func runContainer(image: String, name: String, ports: [String]) async throws {
        try await cli.runContainer(host: selectedHost, image: image, name: name, ports: ports)
        await refreshResources()
    }

    func remove(_ kind: String, id: String) {
        Task {
            do { try await cli.remove(kind: kind, host: selectedHost, id: id) }
            catch { cliError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            await refreshResources()
        }
    }

    func create(_ kind: String, name: String) async throws {
        try await cli.create(kind: kind, host: selectedHost, name: name)
        await refreshResources()
    }

    func machineLifecycle(_ action: String, name: String) {
        Task {
            do { try await cli.machineLifecycle(action, name: name, host: selectedHost) }
            catch { cliError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            await refreshResources()
        }
    }

    func machineDelete(_ name: String) {
        Task {
            do { try await cli.machineDelete(name: name, host: selectedHost) }
            catch { cliError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            await refreshResources()
        }
    }

    func prune(_ kind: String) {
        Task {
            do { try await cli.prune(host: selectedHost, kind: kind) }
            catch { cliError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            await refreshResources()
        }
    }

    // MARK: on-demand port forwards (item 11)

    @Published var forwards: [ActiveForward] = []
    private var forwardCancels: [String: () -> Void] = [:]

    func isForwarding(_ ref: String, containerPort: Int) -> Bool {
        forwardCancels["\(ref)#\(containerPort)"] != nil
    }
    func forward(for ref: String, containerPort: Int) -> ActiveForward? {
        forwards.first { $0.id == "\(ref)#\(containerPort)" }
    }

    func startForward(_ c: Container, containerPort: Int, localPort: Int) {
        let id = "\(c.ref)#\(containerPort)"
        guard forwardCancels[id] == nil else { return }
        let (stream, cancel) = cli.startTunnel(ref: c.ref, localPort: localPort, containerPort: containerPort)
        forwardCancels[id] = cancel
        let fwd = ActiveForward(id: id, ref: c.ref, containerName: c.name, localPort: localPort, containerPort: containerPort)
        Task {
            for await msg in stream {
                if let err = msg.error {
                    cliError = "Port-forward failed: \(err)"
                    break
                }
                if msg.ready == true, !forwards.contains(where: { $0.id == id }) {
                    forwards.append(fwd)
                }
            }
            // Stream ended (process exited or error) — drop the forward.
            forwards.removeAll { $0.id == id }
            forwardCancels[id] = nil
        }
    }

    func stopForward(id: String) {
        forwardCancels[id]?()
        forwardCancels[id] = nil
        forwards.removeAll { $0.id == id }
    }
}
