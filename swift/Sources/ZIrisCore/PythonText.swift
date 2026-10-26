extension String {
    /// Python's str.lower(): the full lowercase mapping plus the Final_Sigma
    /// rule (a capital sigma ending a word becomes ς), which lowercased() skips.
    /// Keys lowercased here must match what the Python version stored.
    public var pythonLowercased: String {
        let scalars = Array(unicodeScalars)
        var out = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\u{03A3}", Self.isFinalSigma(scalars, at: index) {
                out.append("\u{03C2}")
            } else {
                out.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(out)
    }

    private static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        let before = scalars[..<index].reversed().first { !$0.properties.isCaseIgnorable }
        let after = scalars[(index + 1)...].first { !$0.properties.isCaseIgnorable }
        return before?.properties.isCased == true && after?.properties.isCased != true
    }
}
