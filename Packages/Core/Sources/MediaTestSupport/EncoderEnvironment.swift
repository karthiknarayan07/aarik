/// Tests that assert how the real encoder behaves (output size, "saves at least 10%", progress timing) only mean
/// something where the hardware encoder runs. The iOS Simulator's software encoder produces larger files and
/// different timing, so those tests are skipped there and run on the Mac and on a device.
public enum EncoderEnvironment {
    public static let isRepresentative: Bool = {
        #if targetEnvironment(simulator)
            false
        #else
            true
        #endif
    }()
}
