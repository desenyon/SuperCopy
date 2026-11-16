import Foundation
import SuperCopyCore
import Darwin

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.resident_size : 0
}
func milliseconds(_ start: ContinuousClock.Instant) -> Double {
    let elapsed = start.duration(to: .now).components
    return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
}
func percentile(_ values: [Double], _ p: Double) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count - 1) * p))] }
func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

@main struct Diagnostics {
    static func main() async throws {
        let count = max(100, min(20_000, CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 2000))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SuperCopyBenchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(root: root, diskBudget: 0)
        let start = ContinuousClock.now
        let topics = ["automobile maintenance and vehicle repairs", "chocolate cake recipe and baking ingredients", "mountain hiking trails near a lake", "quarterly financial reports and revenue", "Swift programming and memory management"]
        for index in 0..<count {
            let text = "\(topics[index % topics.count]) — note \(index)"
            _ = try await store.insert(ClipboardSnapshot(items: [.init([.init(type: "public.utf8-plain-text", data: Data(text.utf8))])]))
        }
        let insertionMS = milliseconds(start)
        var recentTimes: [Double] = [], searchTimes: [Double] = []
        for index in 0..<60 {
            let start = ContinuousClock.now
            _ = try await store.recent(limit: 80, offset: index % 10 * 80)
            recentTimes.append(milliseconds(start))
        }
        for query in ["car repairs", "cake ingredients", "hiking", "memory", "revenue"] {
            for _ in 0..<12 {
                let start = ContinuousClock.now
                _ = try await store.search(query)
                searchTimes.append(milliseconds(start))
            }
        }
        let warmRSS = residentBytes()
        for _ in 0..<250 { _ = try await store.search("car repairs") }
        let afterRSS = residentBytes()
        var gesture = PasteGesture()
        let gestureStart = ContinuousClock.now
        for _ in 0..<100_000 {
            _ = gesture.handle(.paste(repeated: false)); _ = gesture.handle(.paste(repeated: false)); _ = gesture.handle(.releaseCommand)
        }
        let stats = try await store.statistics()
        let result: [String: Any] = [
            "entries": stats.count, "semanticModelAvailable": stats.semanticAvailable,
            "insertTotalMS": rounded(insertionMS), "insertMeanMS": rounded(insertionMS / Double(count)),
            "recentPageP50MS": rounded(percentile(recentTimes, 0.5)), "recentPageP95MS": rounded(percentile(recentTimes, 0.95)),
            "hybridSearchP50MS": rounded(percentile(searchTimes, 0.5)), "hybridSearchP95MS": rounded(percentile(searchTimes, 0.95)),
            "warmResidentMiB": rounded(Double(warmRSS) / 1048576), "after250SearchesResidentMiB": rounded(Double(afterRSS) / 1048576),
            "residentGrowthMiB": rounded(Double(Int64(afterRSS) - Int64(warmRSS)) / 1048576),
            "gesture100kSessionsMS": rounded(milliseconds(gestureStart)),
            "databaseIntegrity": try await store.integrityCheck()
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
