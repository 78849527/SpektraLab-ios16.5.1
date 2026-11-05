import Foundation
import SwiftUI

/// Local user looks are simple C-ABI parameters, not processed pixels or LUTs.
struct SavedFilmPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var settings: FilmSettings
    var updatedAt: Date
}

struct RecentFilmPair: Codable, Identifiable {
    let filmID: String
    let paperID: String
    var id: String { filmID + ":" + paperID }
}

@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [SavedFilmPreset] = []
    @Published private(set) var recentPairs: [RecentFilmPair] = []

    private let presetKey = "spectraport.local-presets.v1"
    private let recentKey = "spectraport.recent-film-pairs.v1"
    private let defaults = UserDefaults.standard

    init() {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: presetKey),
           let decoded = try? decoder.decode([SavedFilmPreset].self, from: data) {
            presets = decoded.filter { Self.isValid($0.settings) }
                .sorted { $0.updatedAt > $1.updatedAt }
        }
        if let data = defaults.data(forKey: recentKey),
           let decoded = try? decoder.decode([RecentFilmPair].self, from: data) {
            recentPairs = decoded.filter { pair in
                FilmCatalog.films.contains(where: { $0.id == pair.filmID }) &&
                FilmCatalog.papers.contains(where: { $0.id == pair.paperID })
            }
        }
    }

    private static func validMask(_ mask: EditMask) -> Bool {
        guard mask.amount.isFinite, (0...1).contains(mask.amount),
              mask.components.count <= EditMask.maxComponents else { return false }
        let values = mask.adjustments
        guard [values.exposure, values.contrast, values.brightness,
               values.saturation, values.highlights, values.shadows,
               values.blackPoint, values.whitePoint, values.temperature,
               values.tint].allSatisfy(\.isFinite) else { return false }
        return mask.components.allSatisfy { c in
            // Unsupported raster masks cannot appear as silently empty regions.
            guard c.kind != .brush else { return false }
            let numbers: [Double] = [
                Double(c.a.x), Double(c.a.y), Double(c.b.x), Double(c.b.y),
                Double(c.radii.width), Double(c.radii.height),
                c.angle, c.feather, c.low, c.high, c.softness,
                c.tolerance, c.color.x, c.color.y, c.color.z
            ]
            return numbers.allSatisfy(\.isFinite) &&
                (0...1).contains(c.feather) &&
                (0...1).contains(c.low) &&
                (0...1).contains(c.high) &&
                (0...1).contains(c.softness)
        }
    }

    private static func isValid(_ s: FilmSettings) -> Bool {
        FilmCatalog.films.contains(where: { $0.id == s.filmStock }) &&
        FilmCatalog.papers.contains(where: { $0.id == s.printStock }) &&
        (-8.0...8.0).contains(s.exposureEV) &&
        (0.0...2.0).contains(s.grainAmount) &&
        (0.0...4.0).contains(s.halationAmount) &&
        (0.05...20.0).contains(s.printExposure) &&
        (-1.0...1.0).contains(s.magentaShift) &&
        (-1.0...1.0).contains(s.yellowShift) &&
        (0.0...1.0).contains(s.softness) &&
        s.masks.count <= EditMask.maxCount &&
        s.masks.allSatisfy(validMask) &&
        [s.exposureEV, s.grainAmount, s.halationAmount, s.printExposure,
         s.magentaShift, s.yellowShift, s.softness].allSatisfy { $0.isFinite }
    }

    /// Re-saving under the same name updates the look.
    @discardableResult
    func save(name: String, settings: FilmSettings) -> Bool {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !trimmed.isEmpty, Self.isValid(settings) else { return false }
        if let index = presets.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            presets[index].settings = settings
            presets[index].updatedAt = Date()
        } else {
            presets.insert(SavedFilmPreset(
                id: UUID(), name: trimmed, settings: settings, updatedAt: Date()
            ), at: 0)
        }
        presets.sort { $0.updatedAt > $1.updatedAt }
        if presets.count > 30 { presets = Array(presets.prefix(30)) }
        persistPresets()
        return true
    }

    func remove(id: UUID) {
        presets.removeAll { $0.id == id }
        persistPresets()
    }

    func recordUse(_ settings: FilmSettings) {
        let pair = RecentFilmPair(filmID: settings.filmStock, paperID: settings.printStock)
        recentPairs.removeAll { $0.id == pair.id }
        recentPairs.insert(pair, at: 0)
        if recentPairs.count > 6 { recentPairs = Array(recentPairs.prefix(6)) }
        if let data = try? JSONEncoder().encode(recentPairs) {
            defaults.set(data, forKey: recentKey)
        }
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: presetKey)
        }
    }
}
