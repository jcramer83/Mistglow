import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mistglow for macOS")
                .font(.title2)
                .bold()

            Text("Streams your screen and audio over UDP to a MiSTer FPGA running the Groovy_MiSTer core.")

            GroupBox("Quick Start") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Start the Groovy_MiSTer core on your MiSTer FPGA")
                    Text("2. Enter the MiSTer's IP address in the Target IP field")
                    Text("3. Select a modeline preset matching your desired output")
                    Text("4. Configure capture source and crop settings")
                    Text("5. Click Start to begin streaming")
                }
                .font(.callout)
            }

            GroupBox("Modeline Presets") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NTSC presets: 256x240, 320x240, 320x480i, 640x480i, 720x480i")
                    Text("PAL presets: 256x240, 320x240, 320x480i, 640x480i, 720x576i")
                    Text("'i' suffix indicates interlaced mode")
                }
                .font(.callout)
            }

            GroupBox("Crop Modes") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom: Set width, height, and offsets manually")
                    Text("1X-5X: Scale modeline resolution by 1-5x")
                    Text("Full 4:3 / Full 5:4: Match aspect ratio to modeline height")
                }
                .font(.callout)
            }

            GroupBox("Network") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Protocol: UDP on port 32100")
                    Text("MTU: 1472 bytes (standard Ethernet)")
                    Text("Compression: LZ4 with adaptive delta frames")
                    Text("Audio: 48kHz stereo 16-bit PCM")
                }
                .font(.callout)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
        }
        .padding()
        .frame(width: 450)
    }
}
