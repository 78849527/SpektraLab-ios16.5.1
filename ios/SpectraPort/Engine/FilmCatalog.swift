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
    let softness: Double
    /// Desktop's independent post-print Layer 2 (zero = byte-identical).
    let adjustments: Adjustments
    let masks: [EditMask]

    init(filmStock: String, printStock: String, exposureEV: Double,
         grainAmount: Double, halationAmount: Double, printExposure: Double,
         magentaShift: Double, yellowShift: Double, softness: Double = 0,
         adjustments: Adjustments = .default,
         masks: [EditMask] = []) {
        self.filmStock = filmStock
        self.printStock = printStock
        self.exposureEV = exposureEV
        self.grainAmount = grainAmount
        self.halationAmount = halationAmount
        self.printExposure = printExposure
        self.magentaShift = magentaShift
        self.yellowShift = yellowShift
        self.softness = softness
        self.adjustments = adjustments
        self.masks = masks
    }

    private enum CodingKeys: String, CodingKey {
        case filmStock, printStock, exposureEV, grainAmount, halationAmount,
             printExposure, magentaShift, yellowShift, softness, adjustments, masks
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filmStock = try values.decode(String.self, forKey: .filmStock)
        printStock = try values.decode(String.self, forKey: .printStock)
        exposureEV = try values.decode(Double.self, forKey: .exposureEV)
        grainAmount = try values.decode(Double.self, forKey: .grainAmount)
        halationAmount = try values.decode(Double.self, forKey: .halationAmount)
        printExposure = try values.decode(Double.self, forKey: .printExposure)
        magentaShift = try values.decode(Double.self, forKey: .magentaShift)
        yellowShift = try values.decode(Double.self, forKey: .yellowShift)
        // Old presets were written before the softness parameter existed.
        softness = try values.decodeIfPresent(Double.self, forKey: .softness) ?? 0
        adjustments = try values.decodeIfPresent(
            Adjustments.self, forKey: .adjustments
        ) ?? .default
        masks = try values.decodeIfPresent(
            [EditMask].self, forKey: .masks
        ) ?? []
    }

    /// Layer 2 adjustments and local masks are strictly post-print.
    /// Do not send their changes to the original spectral engine.
    func samePhysicalPrint(as other: FilmSettings) -> Bool {
        filmStock == other.filmStock &&
        printStock == other.printStock &&
        exposureEV == other.exposureEV &&
        grainAmount == other.grainAmount &&
        halationAmount == other.halationAmount &&
        printExposure == other.printExposure &&
        magentaShift == other.magentaShift &&
        yellowShift == other.yellowShift &&
        softness == other.softness
    }

    func deltaJSON(striped: Bool = false,
                   filmEdge: MobileFilmEdgeSettings = MobileFilmEdgeSettings(),
                   geometry: PhotoGeometry = .identity,
                   filmName: String = "") throws -> String {
        // Native RFC-031/032 parameters: crop and imprint are part of the
        // negative exposure, before printing. Keep these names in sync with
        // engine/src/core/params.cpp.
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
            "y_filter_shift": yellowShift,
            "geometry_crop_x": Double(geometry.crop.minX),
            "geometry_crop_y": Double(geometry.crop.minY),
            "geometry_crop_w": Double(geometry.crop.width),
            "geometry_crop_h": Double(geometry.crop.height),
            "geometry_quarter_turns": geometry.quarterTurns,
            "geometry_rotation_deg": geometry.straightenDegrees,
            "geometry_flip_h": geometry.flipHorizontal,
            "geometry_flip_v": geometry.flipVertical,
            "overscan_active": filmEdge.enabled,
            "overscan_format": filmEdge.format.rawValue,
            "overscan_mode": filmEdge.view == .strip ? "strip" : "filed",
            "overscan_gate": filmEdge.gate.engineValue,
            "overscan_holes": filmEdge.holes == .white ? "white" : "black",
            "overscan_frame_number": filmEdge.frameNumber,
            "overscan_camera_seed": 1,
            "overscan_frame_seed": 1,
            "overscan_fog": filmEdge.enabled ? filmEdge.fog : 0,
            "overscan_leaks": filmEdge.enabled ? filmEdge.leaks : 0,
            "overscan_edge_text": filmEdge.edgeText.isEmpty ? filmName : filmEdge.edgeText,
            "overscan_f_number": 0.0,
            "overscan_carrier": "none",
            "overscan_pair": false,
            "date_imprint_active": filmEdge.dateBack.enabled,
            "date_imprint_text": filmEdge.dateBack.face == .data ? "" : filmEdge.dateBack.printedText,
            "date_imprint_data_text": filmEdge.dateBack.withData ? filmEdge.dateBack.dataText : "",
            "date_imprint_style": filmEdge.dateBack.face == .lcd ? "lcd" :
                (filmEdge.dateBack.face == .dots ? "dots" : "data"),
            "date_imprint_placement": filmEdge.dateBack.placement == .rebate && filmEdge.enabled ? "rebate" : "frame",
            "date_imprint_corner": filmEdge.dateBack.corner.rawValue.lowercased(),
            "date_imprint_inset_x": filmEdge.dateBack.insetXMM,
            "date_imprint_inset_y": filmEdge.dateBack.insetYMM,
            "date_imprint_size": filmEdge.dateBack.size,
            "date_imprint_ev": filmEdge.dateBack.brightnessEV
        ]
        if striped && !filmEdge.needsComposite {
            values["striped"] = true
            values["strip_rows"] = 0
        } else {
            values["striped"] = false
        }
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
