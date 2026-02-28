import Foundation

struct Modeline: Codable, Equatable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var pClock: Double
    var hActive: UInt16
    var hBegin: UInt16
    var hEnd: UInt16
    var hTotal: UInt16
    var vActive: UInt16
    var vBegin: UInt16
    var vEnd: UInt16
    var vTotal: UInt16
    var interlace: Bool

    var rgbSize: Int {
        let pixels = Int(hActive) * Int(vActive) * 3
        return interlace ? pixels / 2 : pixels
    }

    static let presets: [Modeline] = [
        Modeline(name: "256x240 NTSC",  pClock: 4.905,  hActive: 256, hBegin: 264, hEnd: 287, hTotal: 312, vActive: 240, vBegin: 241, vEnd: 244, vTotal: 262, interlace: false),
        Modeline(name: "320x240 NTSC",  pClock: 6.700,  hActive: 320, hBegin: 336, hEnd: 367, hTotal: 426, vActive: 240, vBegin: 244, vEnd: 247, vTotal: 262, interlace: false),
        Modeline(name: "320x480i NTSC", pClock: 6.700,  hActive: 320, hBegin: 336, hEnd: 367, hTotal: 426, vActive: 480, vBegin: 488, vEnd: 493, vTotal: 525, interlace: true),
        Modeline(name: "640x480i NTSC", pClock: 12.336, hActive: 640, hBegin: 662, hEnd: 720, hTotal: 784, vActive: 480, vBegin: 488, vEnd: 494, vTotal: 525, interlace: true),
        Modeline(name: "720x480i NTSC", pClock: 13.846, hActive: 720, hBegin: 744, hEnd: 809, hTotal: 880, vActive: 480, vBegin: 488, vEnd: 494, vTotal: 525, interlace: true),
        Modeline(name: "256x240 PAL",   pClock: 5.320,  hActive: 256, hBegin: 269, hEnd: 294, hTotal: 341, vActive: 240, vBegin: 270, vEnd: 273, vTotal: 312, interlace: false),
        Modeline(name: "320x240 PAL",   pClock: 6.660,  hActive: 320, hBegin: 336, hEnd: 367, hTotal: 426, vActive: 240, vBegin: 270, vEnd: 273, vTotal: 312, interlace: false),
        Modeline(name: "320x480i PAL",  pClock: 6.660,  hActive: 320, hBegin: 336, hEnd: 367, hTotal: 426, vActive: 480, vBegin: 540, vEnd: 545, vTotal: 625, interlace: true),
        Modeline(name: "640x480i PAL",  pClock: 13.320, hActive: 640, hBegin: 672, hEnd: 734, hTotal: 852, vActive: 480, vBegin: 540, vEnd: 545, vTotal: 625, interlace: true),
        Modeline(name: "720x576i PAL",  pClock: 13.875, hActive: 720, hBegin: 741, hEnd: 806, hTotal: 888, vActive: 576, vBegin: 581, vEnd: 586, vTotal: 625, interlace: true),
    ]

    static let defaultPreset = presets[1] // 320x240 NTSC
}
