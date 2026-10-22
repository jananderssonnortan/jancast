import AppKit
import Observation

/// Preview thumbnails for one file (GET /api/thumbs): polls until the backend
/// has made them all, and loads images on demand into a small cache. Views ask
/// for `image(at:)`; until the exact thumbnail arrives they get the nearest
/// one already loaded, so hovering never flickers to empty.
@MainActor
@Observable
final class Thumbnails {
    private(set) var path: String?
    private(set) var info: ThumbsInfo?
    /// The film as bands of colour (one pixel per thumbnail), once made.
    private(set) var palette: NSImage?
    /// No palette will come (thumbnails failed, or the palette wasn't made):
    /// the timeline falls back to the film roll.
    private(set) var paletteUnavailable = false
    private var images: [Int: NSImage] = [:]

    @ObservationIgnored private var backend: Backend?
    @ObservationIgnored private var loading = Set<Int>()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Frames the film roll shows; never evicted (most recent 32).
    @ObservationIgnored private var pinned: [Int] = []

    private static let maxCached = 240

    var available: Bool { (info?.count ?? 0) > 0 }
    /// How far making the timeline has got (thumbnails, then the palette), 0…1.
    var timelineProgress: Double {
        guard let i = info, let total = i.total, total > 0 else { return 0 }
        return i.done == true ? 0.99 : min(0.98, Double(i.count) / Double(total))
    }
    var aspect: Double { info?.aspect ?? 16.0 / 9.0 }

    /// Follow `path` (nil = nothing to show). Cheap to call on every poll.
    func track(path newPath: String?, backend: Backend) {
        guard newPath != path || self.backend !== backend else { return }
        self.backend = backend
        path = newPath
        info = nil
        palette = nil
        paletteUnavailable = false
        images = [:]
        loading = []
        pinned = []
        generation += 1
        pollTask?.cancel()
        guard let newPath else { return }
        let gen = generation
        pollTask = Task { [weak self] in
            var delay: UInt64 = 500_000_000
            var waitsForPalette = 6         // made right after the thumbnails (or for old caches)
            while !Task.isCancelled {
                guard let self, self.generation == gen else { return }
                if let i = try? await backend.thumbs(path: newPath, make: true), self.generation == gen {
                    self.info = i
                    if i.palette != nil, self.palette == nil,
                       let p = try? await backend.palette(i), self.generation == gen {
                        self.palette = p
                    }
                    if i.failed == true { self.paletteUnavailable = true; return }
                    if i.done == true {
                        if self.palette != nil { return }
                        if waitsForPalette == 0 { self.paletteUnavailable = true; return }
                        waitsForPalette -= 1
                    }
                }
                try? await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 3_000_000_000)
            }
        }
    }

    /// 1-based thumbnail index for a position, clamped to what exists so far.
    func index(at seconds: Double) -> Int? {
        guard let i = info, i.count > 0, i.intervalS > 0 else { return nil }
        return max(1, min(i.count, Int((max(0, seconds) / i.intervalS).rounded(.down)) + 1))
    }

    /// Thumbnail for a position: exact if loaded, else the nearest loaded one.
    /// Starts loading the exact one (and its neighbours) as a side effect.
    /// `pin` keeps it in the cache (the film roll's frames): otherwise hovering
    /// a long file evicted the roll's first and last frames, which then
    /// flashed as they reloaded.
    func image(at seconds: Double, pin: Bool = false) -> NSImage? {
        guard let idx = index(at: seconds) else { return nil }
        if pin, !pinned.contains(idx) {
            pinned.append(idx)
            if pinned.count > 32 { pinned.removeFirst() }
        }
        request(idx)
        if let img = images[idx] { return img }
        return images.min { abs($0.key - idx) < abs($1.key - idx) }?.value
    }

    /// Loads ahead of time (e.g. the next few around the playhead).
    func prefetch(around seconds: Double, count: Int = 3) {
        guard let idx = index(at: seconds) else { return }
        for i in idx...(idx + count) { request(i) }
    }

    /// One poster frame for a list row: only if thumbnails already exist for
    /// that file (never starts ffmpeg). Cached per path.
    static func poster(path: String, at seconds: Double?, backend: Backend) async -> NSImage? {
        if let hit = posterCache[path] { return hit }
        guard let info = try? await backend.thumbs(path: path, make: false), info.count > 0 else { return nil }
        let idx = max(1, min(info.count, Int((seconds ?? Double(info.count) * info.intervalS * 0.1) / info.intervalS) + 1))
        guard let img = try? await backend.thumbnail(info, index: idx) else { return nil }
        posterCache[path] = img
        return img
    }

    private static var posterCache: [String: NSImage] = [:]

    private func request(_ idx: Int) {
        guard let info, let backend, idx >= 1, idx <= info.count,
              images[idx] == nil, !loading.contains(idx) else { return }
        loading.insert(idx)
        let gen = generation
        // Deferred: views call image(at:) while rendering, where state must not change.
        Task { [weak self] in
            let img = try? await backend.thumbnail(info, index: idx)
            guard let self, self.generation == gen else { return }
            self.loading.remove(idx)
            guard let img else { return }
            if self.images.count >= Self.maxCached {
                // Evict the one farthest from what was just asked for.
                if let far = self.images.keys.filter({ !self.pinned.contains($0) })
                    .max(by: { abs($0 - idx) < abs($1 - idx) }) { self.images[far] = nil }
            }
            self.images[idx] = img
        }
    }
}
