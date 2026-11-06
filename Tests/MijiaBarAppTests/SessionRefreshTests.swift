import Foundation
import Testing
import MijiaCore
@testable import MijiaBarApp

@Suite @MainActor struct AppSessionRefreshTests {
    @Test func regionUsesPersistedCredentialsAndIgnoresOldNotification() {
        let model = AppModel(mock: true)
        let old = Session(userId: "synthetic", ssecurity: "old", serviceToken: "old", region: "cn")
        let latest = Session(userId: "synthetic", ssecurity: "new", serviceToken: "new", region: "cn")
        model.installCloud(old)
        let identity = model.cloudIdentity
        var savedFresh = false
        model.changeRegionSession("de", load: { latest }, save: { value in
            savedFresh = value.ssecurity == latest.ssecurity && value.serviceToken == latest.serviceToken && value.region == "de"
        })
        model.acceptSession(old, identity: identity)
        let keptFresh = model.session?.serviceToken == latest.serviceToken && model.session?.region == "de"
        #expect(savedFresh); #expect(keptFresh)
        model.acceptSession(Session(userId: "synthetic", ssecurity: "newest", serviceToken: "newest", region: "de"), identity: model.cloudIdentity)
        let acceptedCurrent = model.session?.serviceToken == "newest"
        #expect(acceptedCurrent)
        model.controller.cloud?.invalidate()
    }
}
