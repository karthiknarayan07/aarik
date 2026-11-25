public enum MetadataDiff {
    /// Compares by key. Same value is kept, different value is changed, missing from the
    /// output is lost. Output-only keys are ignored. Results follow source order, and the
    /// first occurrence of a duplicated source key wins.
    public static func report(source: MetadataInventory, output: MetadataInventory)
        -> MetadataReport
    {
        var outputByKey: [String: MetadataItem] = [:]
        for item in output.items where outputByKey[item.key] == nil {
            outputByKey[item.key] = item
        }
        var seen = Set<String>()
        var report = MetadataReport()
        for item in source.items where seen.insert(item.key).inserted {
            guard let out = outputByKey[item.key] else {
                report.lost.append(item)
                continue
            }
            if out.value == item.value {
                report.kept.append(item)
            } else {
                report.changed.append(
                    MetadataChange(
                        key: item.key, displayName: item.displayName,
                        from: item.value, to: out.value))
            }
        }
        return report
    }
}
