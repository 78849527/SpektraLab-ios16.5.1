import Foundation

/// All entries are read from the upstream measured profile JSON shipped with
/// the engine. No imitation LUT catalogue or hard-coded film names.
enum FilmCatalog {
    struct Stock: Identifiable, Hashable {
        let id: String
        let name: String
        let targetPrint: String?
    }

    private static let entries: [(stock: Stock, info: [String: Any])] = {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("engine/profiles"),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return urls.filter { $0.pathExtension.lowercased() == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = json["info"] as? [String: Any],
                  let stock = info["stock"] as? String,
                  let name = info["name"] as? String else {
                return nil
            }
            let candidate = Stock(id: stock, name: name, targetPrint: info["target_print"] as? String)
            return (stock: candidate, info: info)
        }
    }()

    // Initially expose measured colour-negative films, including cine
    // negatives. Positive/B&W stocks require separate pairing verification.
    static let films: [Stock] = entries.filter { item in
        item.info["support"] as? String == "film" &&
        item.info["stage"] as? String == "filming" &&
        item.info["type"] as? String == "negative" &&
        item.info["channel_model"] as? String == "color"
    }.map(\.stock).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    static let papers: [Stock] = entries.filter { item in
        item.info["support"] as? String == "paper" &&
        item.info["stage"] as? String == "printing" &&
        item.info["channel_model"] as? String == "color"
    }.map(\.stock).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    static func filmName(_ id: String) -> String { films.first(where: { $0.id == id })?.name ?? id }
    static func paperName(_ id: String) -> String { papers.first(where: { $0.id == id })?.name ?? id }
}

struct FilmSettings: Equatable, Codable {
    let filmStock: String
    let printStock: String
    let exposureEV: Double
    let grainAmount: Double
    let halationAmount: Double
    let printExposure: Double
    let magentaShift: Double
    let yellowShift: Double

    func deltaJSON(striped: Bool = false) throws -> String {
        // These exact field names and ranges come from engine/src/core/params.cpp.
        // Keep colour-management fields identical to the successful v0.2.1 path.
        var values: [String: Any] = [
            "input_color_space": "ProPhoto RGB",
            "input_cctf_decoding": true,
            "product_defaults": true,
            "filter_shift_scale": 40.0,
            "film_stock": filmStock,
            "print_stock": printStock,
            "exposure_compensation_ev": exposureEV,
            "grain_amount": grainAmount,
            "halation_amount": halationAmount,
            "halation_active": halationAmount > 0,
            "print_exposure": printExposure,
            "m_filter_shift": magentaShift,
            "y_filter_shift": yellowShift
        ]
        if striped { values["striped"] = true; values["strip_rows"] = 0 }
        let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw PortError.message("无法编码胶片参数")
        }
        return json
    }

    /// Only send fields that changed. Omitting film_stock and print_stock lets
    /// spk_set_params retain the measured profile and cached negative for a
    /// print-only edit, instead of needlessly rebuilding the whole session.
    func changedDeltaJSON(from previous: FilmSettings) throws -> String {
        var changes: [String: Any] = [:]
        if filmStock != previous.filmStock { changes["film_stock"] = filmStock }
        if printStock != previous.printStock { changes["print_stock"] = printStock }
        if exposureEV != previous.exposureEV { changes["exposure_compensation_ev"] = exposureEV }
        if grainAmount != previous.grainAmount { changes["grain_amount"] = grainAmount }
        if halationAmount != previous.halationAmount {
            changes["halation_amount"] = halationAmount
            changes["halation_active"] = halationAmount > 0
        }
        if printExposure != previous.printExposure { changes["print_exposure"] = printExposure }
        if magentaShift != previous.magentaShift { changes["m_filter_shift"] = magentaShift }
        if yellowShift != previous.yellowShift { changes["y_filter_shift"] = yellowShift }
        let data = try JSONSerialization.data(withJSONObject: changes, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw PortError.message("无法编码更改的参数")
        }
        return result
    }
}
