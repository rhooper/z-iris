import Testing
@testable import ZIrisMac

@Suite struct HelperLifetimeTests {
    @Test func aHelperStartedByZIrisQuitsWithIt() {
        let life = HelperLifetime(parent: 4242)
        #expect(!life.orphaned(currentParent: 4242))
        #expect(life.orphaned(currentParent: 1))  // z-iris quit, crashed or was killed: launchd adopted it
        #expect(life.graceAfterInput == 0)  // its pipe closed: z-iris is gone, so go now
    }

    @Test func aHelperMacOSLaunchedForAClickWaitsForIt() {
        let life = HelperLifetime(parent: 1)
        #expect(!life.orphaned(currentParent: 1))
        #expect(life.graceAfterInput == 30)
    }
}
