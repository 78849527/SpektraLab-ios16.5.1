import CoreGraphics
import Foundation

/// Maps the mobile editor state onto the original RFC-031/032 engine wire.
/// Crop and date/edge exposure are applied before the native film negative is
/// developed; this adapter deliberately contains no output-image compositor.
extension FilmSettings {
    func deltaJSON(
        striped: Bool,
        inputCCTFDecoding: Bool = true,
        filmEdge: MobileFilmEdgeSettings,
        geometry: PhotoGeometry,
        inputSize: CGSize,
        filmName: String
    ) throws -> String {
        let base = try deltaJSON(striped: false, inputCCTFDecoding: inputCCTFDecoding)
        guard let data = base.data(using: .utf8),
              var values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PortError.message("无法读取原版胶片参数")
        }

        let nativeEdge = filmEdge.needsComposite
        let nativeGeometry = nativeEdge ? geometry : .identity
        var crop = PhotoGeometry.bounded(nativeGeometry.crop)
        if filmEdge.enabled && inputSize.width > 0 && inputSize.height > 0 {
            var imageAspect = inputSize.width / inputSize.height
            if nativeGeometry.quarterTurns % 2 != 0 { imageAspect = 1 / imageAspect }
            let gate = filmEdge.format.gateMM
            let targetAspect = max(gate.width, gate.height) / min(gate.width, gate.height)
            let cropAspect = imageAspect * crop.width / crop.height
            if cropAspect > targetAspect {
                let fittedWidth = crop.width * targetAspect / cropAspect
                crop.origin.x += (crop.width - fittedWidth) / 2
                crop.size.width = fittedWidth
            } else if cropAspect < targetAspect {
                let fittedHeight = crop.height * cropAspect / targetAspect
                crop.origin.y += (crop.height - fittedHeight) / 2
                crop.size.height = fittedHeight
            }
        }

        values["geometry_crop_x"] = Double(crop.minX)
        values["geometry_crop_y"] = Double(crop.minY)
        values["geometry_crop_w"] = Double(crop.width)
        values["geometry_crop_h"] = Double(crop.height)
        values["geometry_quarter_turns"] = nativeGeometry.quarterTurns
        values["geometry_rotation_deg"] = nativeGeometry.straightenDegrees
        values["geometry_flip_h"] = nativeGeometry.flipHorizontal
        values["geometry_flip_v"] = nativeGeometry.flipVertical

        values["overscan_active"] = filmEdge.enabled
        values["overscan_format"] = filmEdge.format.rawValue
        values["overscan_mode"] = filmEdge.view == .strip ? "strip" : "filed"
        values["overscan_gate"] = filmEdge.gate.engineValue
        values["overscan_holes"] = filmEdge.holes == .white ? "white" : "black"
        values["overscan_frame_number"] = filmEdge.frameNumber
        values["overscan_camera_seed"] = 1
        values["overscan_frame_seed"] = 1
        values["overscan_fog"] = filmEdge.enabled ? filmEdge.fog : 0
        values["overscan_leaks"] = filmEdge.enabled ? filmEdge.leaks : 0
        values["overscan_edge_text"] = filmEdge.edgeText.isEmpty ? filmName : filmEdge.edgeText
        values["overscan_f_number"] = 0.0
        values["overscan_carrier"] = "none"
        values["overscan_pair"] = false

        let date = filmEdge.dateBack
        values["date_imprint_active"] = date.enabled
        values["date_imprint_text"] = date.printedText
        values["date_imprint_data_text"] = date.withData ? date.dataText : ""
        values["date_imprint_style"] = date.face == .lcd ? "lcd" :
            (date.face == .dots ? "dots" : "data")
        values["date_imprint_placement"] =
            date.placement == .rebate && filmEdge.enabled ? "rebate" : "frame"
        values["date_imprint_corner"] = date.corner.engineValue
        values["date_imprint_inset_x"] = date.insetXMM
        values["date_imprint_inset_y"] = date.insetYMM
        values["date_imprint_size"] = date.size
        values["date_imprint_ev"] = date.brightnessEV

        if nativeEdge || !striped {
            values["striped"] = false
        } else {
            values["striped"] = true
            values["strip_rows"] = 0
        }

        let encoded = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw PortError.message("无法编码原版片边参数")
        }
        return json
    }
}
