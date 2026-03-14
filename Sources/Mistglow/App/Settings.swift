import Foundation

enum Alignment: String, Codable, CaseIterable {
    case topLeft, topCenter, topRight
    case middleLeft, center, middleRight
    case bottomLeft, bottomCenter, bottomRight

    var displayName: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .middleLeft: "Middle Left"
        case .center: "Center"
        case .middleRight: "Middle Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }
}

enum Rotation: String, Codable, CaseIterable {
    case none
    case ccw90
    case cw90
    case rotate180

    var displayName: String {
        switch self {
        case .none: "None"
        case .ccw90: "90° CCW"
        case .cw90: "90° CW"
        case .rotate180: "180°"
        }
    }
}

enum CropMode: String, Codable, CaseIterable {
    case custom
    case scale1x
    case scale2x
    case scale3x
    case scale4x
    case scale5x
    case full43
    case full54

    var displayName: String {
        switch self {
        case .custom: "Custom"
        case .scale1x: "1X"
        case .scale2x: "2X"
        case .scale3x: "3X"
        case .scale4x: "4X"
        case .scale5x: "5X"
        case .full43: "Full 4:3"
        case .full54: "Full 5:4"
        }
    }
}

struct AppSettings: Codable {
    var targetIP: String = "MiSTer"
    var modeline: Modeline = Modeline.presets[3] // 640x480i NTSC
    var displayIndex: Int = 1
    var alignment: Alignment = .center
    var rotation: Rotation = .none
    var audioEnabled: Bool = true
    var previewEnabled: Bool = false
    var cropMode: CropMode = .full43
    var cropWidth: Int = 0
    var cropHeight: Int = 0
    var cropOffsetX: Int = 0
    var cropOffsetY: Int = 0
    var webURL: String = "https://weatherstar.netbymatt.com/?hazards-checkbox=true&current-weather-checkbox=true&latest-observations-checkbox=true&hourly-checkbox=true&hourly-graph-checkbox=true&travel-checkbox=true&regional-forecast-checkbox=true&local-forecast-checkbox=true&extended-forecast-checkbox=true&almanac-checkbox=true&spc-outlook-checkbox=true&radar-checkbox=true&settings-wide-checkbox=false&settings-kiosk-checkbox=false&settings-stickyKiosk-checkbox=false&settings-customTextEnable-checkbox=false&settings-speed-select=1.00&settings-scanLineMode-select=auto&settings-units-select=us&txtLocation=53177&settings-customText-string=Cramer&share-link-url=&settings-scanLines-checkbox=false&settings-mediaVolume-select=0.75&latLonQuery=53177&latLon=%7B%22lat%22%3A42.6932%2C%22lon%22%3A-87.9145%7D"
    var webURLHistory: [String] = []
    var plexAutoModeline: Bool = false
    var plexEnabled: Bool = false
    var plexResourceIdentifier: String = UUID().uuidString

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Mistglow")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.fileURL)
        }
    }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func saveToURL(_ url: URL) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url)
        }
    }

    static func loadFromURL(_ url: URL) -> AppSettings? {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return nil
        }
        return settings
    }
}
