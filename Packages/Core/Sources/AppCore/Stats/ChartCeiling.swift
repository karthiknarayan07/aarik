/// The top of a bar or line chart's value axis. A chart whose values are all zero (nothing saved yet, an empty
/// queue) would get a zero-length domain, which Swift Charts can't lay out; the ceiling is never below 1.
public enum ChartCeiling {
    public static func of<Values: Sequence>(_ values: Values) -> Values.Element where Values.Element: BinaryInteger {
        max(1, values.max() ?? 0)
    }
}
