import Darwin
import Testing
@testable import HeyEQQCore

@Suite struct AudioProcessTests {
    private func p(_ id: UInt32, _ bundle: String) -> AudioProcess {
        AudioProcess(objectID: id, pid: pid_t(id), bundleID: bundle, isRunningOutput: false)
    }

    @Test func helpersBelongToTheirApp() {
        #expect(p(1, "com.google.Chrome.helper").belongs(to: "com.google.Chrome"))
        #expect(p(2, "com.google.Chrome").belongs(to: "com.google.Chrome"))
        #expect(!p(3, "com.google.Chromecast").belongs(to: "com.google.Chrome"))
        #expect(!p(4, "").belongs(to: ""))
    }

    @Test func routesEachProcessToMostSpecificRule() {
        let procs = [p(1, "com.spotify.client"), p(2, "com.spotify.client.helper"),
                     p(3, "com.google.Chrome.helper"), p(4, "com.apple.Music"), p(5, "")]
        let routes = AudioProcessCatalog.processes(for: ["com.spotify.client", "com.spotify.client.helper", "com.google.Chrome", "org.absent"],
                                                   in: procs)
        #expect(routes["com.spotify.client"] == [1])
        #expect(routes["com.spotify.client.helper"] == [2])
        #expect(routes["com.google.Chrome"] == [3])
        #expect(routes["org.absent"] == nil)
    }
}
