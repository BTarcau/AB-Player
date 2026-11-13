import SwiftUI

/// Credits and licences for the voices and libraries Lamplight is built on.
struct AcknowledgementsView: View {
    private struct Credit: Identifiable {
        let name: String, license: String, detail: String, url: String
        var id: String { name }
    }

    private let credits: [Credit] = [
        Credit(name: "Pocket TTS", license: "CC BY 4.0",
               detail: "The cloned narrator voices use Pocket TTS by Kyutai (kyutai.org). This app runs an int8 ONNX export of the model (by KevinAHM, packaged by the sherpa-onnx project); the model itself is unchanged apart from that conversion.",
               url: "https://github.com/kyutai-labs/pocket-tts"),
        Credit(name: "sherpa-onnx", license: "Apache-2.0",
               detail: "Runs Pocket TTS on this device. By the k2-fsa project (Xiaomi Corporation and contributors).",
               url: "https://github.com/k2-fsa/sherpa-onnx"),
        Credit(name: "ONNX Runtime", license: "MIT", detail: "By Microsoft. Used by sherpa-onnx.",
               url: "https://github.com/microsoft/onnxruntime"),
        Credit(name: "Kokoro-82M", license: "Apache-2.0", detail: "The Kokoro voices, by hexgrad.",
               url: "https://huggingface.co/hexgrad/Kokoro-82M"),
        Credit(name: "kokoro-coreml", license: "Apache-2.0", detail: "Runs Kokoro on the Neural Engine. By Matt Mireles.",
               url: "https://github.com/mattmireles/kokoro-coreml"),
        Credit(name: "MisakiSwift", license: "Apache-2.0", detail: "Turns text into Kokoro's phonemes.",
               url: "https://github.com/mattmireles/MisakiSwift"),
        Credit(name: "MLX Swift", license: "MIT", detail: "By Apple. Used by MisakiSwift.",
               url: "https://github.com/ml-explore/mlx-swift"),
        Credit(name: "ZIPFoundation", license: "MIT", detail: "By Thomas Zoechling.",
               url: "https://github.com/weichsel/ZIPFoundation"),
    ]

    var body: some View {
        List(credits) { c in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(c.name).font(.headline)
                    Spacer()
                    Text(c.license).font(.caption).foregroundStyle(.secondary)
                }
                Text(c.detail).font(.subheadline)
                if let url = URL(string: c.url) { Link(c.url, destination: url).font(.caption) }
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
