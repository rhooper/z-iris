import Testing
import ZIrisCore

@Suite struct PlainTextParity {
    @Test(arguments: Fixture.load("plain"))
    func plain(_ fixture: Fixture) {
        #expect(plainText(fixture.input["text"] as! String) == fixture.expected as! String)
    }
}
