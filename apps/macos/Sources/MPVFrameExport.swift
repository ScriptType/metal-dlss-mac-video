import CMpv
import CoreMedia
import CoreVideo
import Foundation

/// Optional extension; absence leaves ordinary libmpv playback intact.
final class MPVFrameExportAPI: @unchecked Sendable {
    typealias Open = @convention(c) (OpaquePointer?, UInt32, UnsafeMutablePointer<OpaquePointer?>?) -> mpv_hdr_status
    typealias Poll = @convention(c) (OpaquePointer?, UInt64, UnsafeMutablePointer<mpv_hdr_snapshot>?, UnsafeMutablePointer<OpaquePointer?>?) -> mpv_hdr_status
    typealias Get = @convention(c) (OpaquePointer?) -> UnsafePointer<mpv_hdr_frame_descriptor>?
    typealias Current = @convention(c) (OpaquePointer?) -> Int32
    typealias Release = @convention(c) (OpaquePointer?) -> Void
    let open: Open, poll: Poll, get: Get, current: Current, release: Release, close: Release
    init?(library: UnsafeMutableRawPointer) {
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let open = symbol("mpv_hdr_export_open", Open.self),
              let poll = symbol("mpv_hdr_export_poll", Poll.self),
              let get = symbol("mpv_hdr_frame_get", Get.self),
              let current = symbol("mpv_hdr_frame_is_current", Current.self),
              let release = symbol("mpv_hdr_frame_release", Release.self),
              let close = symbol("mpv_hdr_export_close", Release.self) else { return nil }
        self.open = open; self.poll = poll; self.get = get; self.current = current; self.release = release; self.close = close
    }
}

final class NativePiPFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let state: mpv_hdr_snapshot
    let source: String
    let videoTrackID: Int32
    private let lease: OpaquePointer
    private let api: MPVFrameExportAPI
    init?(lease: OpaquePointer, api: MPVFrameExportAPI) {
        guard let descriptor = api.get(lease)?.pointee,
              descriptor.abi_version == MPV_HDR_EXPORT_ABI_VERSION,
              let pixel = descriptor.pixel_buffer else { api.release(lease); return nil }
        self.lease = lease; self.api = api
        pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pixel).takeUnretainedValue()
        state = descriptor.selected
        source = descriptor.source_path.map { String(cString: $0) } ?? ""
        videoTrackID = descriptor.video_track_id
    }
    var isCurrent: Bool { api.current(lease) != 0 }
    deinit { api.release(lease) }
}

final class NativePiPSnapshot: @unchecked Sendable {
    let state: mpv_hdr_snapshot
    let frame: NativePiPFrame?
    let unavailableReason: String?
    init(state: mpv_hdr_snapshot = mpv_hdr_snapshot(), frame: NativePiPFrame? = nil, unavailableReason: String? = nil) {
        self.state = state; self.frame = frame; self.unavailableReason = unavailableReason
    }
}

/// One latest snapshot and one scheduled callback, regardless of producer rate.
final class NativePiPMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: NativePiPSnapshot?
    private var scheduled = false
    private var closed = false
    private let consume: @MainActor @Sendable (NativePiPSnapshot) -> Void
    private let clock: NativePiPCoreClock?
    init(clock: NativePiPCoreClock?, consume: @escaping @MainActor @Sendable (NativePiPSnapshot) -> Void) { self.clock = clock; self.consume = consume }
    func submit(_ snapshot: NativePiPSnapshot) {
        clock?.update(snapshot)
        lock.lock()
        guard !closed else { lock.unlock(); return }
        // A clock-only poll must not discard an undelivered frame of the same
        // revision. New epochs/generations/revisions replace it immediately.
        if snapshot.frame == nil, let prior = latest, prior.frame != nil,
           snapshot.state.supported != 0, snapshot.state.stream_epoch == prior.state.stream_epoch,
           snapshot.state.generation == prior.state.generation, snapshot.state.revision == prior.state.revision {
            latest = NativePiPSnapshot(state: snapshot.state, frame: prior.frame, unavailableReason: snapshot.unavailableReason)
        } else { latest = snapshot }
        let schedule = !scheduled; scheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { [self] in drain() } }
    }
    @MainActor private func drain() {
        lock.lock(); let value = latest; latest = nil; scheduled = false; let stopped = closed; lock.unlock()
        if !stopped, let value { consume(value) }
    }
    func close() { lock.lock(); closed = true; latest = nil; lock.unlock() }
}

/// Owned and polled exclusively by the existing native client worker.
final class MPVFrameExporter {
    private let api: MPVFrameExportAPI
    private var exporter: OpaquePointer?
    private var revision: UInt64 = 0
    init?(api: MPVFrameExportAPI?, client: OpaquePointer) {
        guard let api else { return nil }
        var exporter: OpaquePointer?
        guard api.open(client, 3, &exporter) == MPV_HDR_FRAME_READY, let exporter else { return nil }
        self.api = api; self.exporter = exporter
    }
    func poll() -> NativePiPSnapshot {
        guard let exporter else { return NativePiPSnapshot(unavailableReason: "The PiP frame exporter is closed.") }
        var state = mpv_hdr_snapshot()
        state.struct_size = UInt32(MemoryLayout<mpv_hdr_snapshot>.size)
        state.abi_version = UInt32(MPV_HDR_EXPORT_ABI_VERSION)
        var raw: OpaquePointer?
        let result = api.poll(exporter, revision, &state, &raw)
        let frame = raw.flatMap { NativePiPFrame(lease: $0, api: api) }
        if frame != nil { revision = state.revision }
        let error = result == MPV_HDR_INVALID || result == MPV_HDR_CLOSED ? "The PiP frame exporter is unavailable." : nil
        return NativePiPSnapshot(state: state, frame: frame, unavailableReason: error)
    }
    func close() { if let exporter { self.exporter = nil; api.close(exporter) } }
    deinit { close() }
}
