import Combine
import Foundation

/// 스윙 기록을 JSON 파일로 저장/로드한다. 메인 큐에서만 사용.
final class SwingStore: ObservableObject {

    @Published private(set) var records: [SwingRecord] = []

    private let ioQueue = DispatchQueue(label: "swingwatch.store", qos: .utility)

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("swing_history.json")
    }

    init() {
        load()
    }

    func add(_ record: SwingRecord) {
        records.append(record)
        save()
    }

    func deleteAll() {
        let fileNames = Set(records.compactMap { $0.videoFileName })
        records.removeAll()
        save()
        ioQueue.async {
            for name in fileNames {
                try? FileManager.default.removeItem(
                    at: SessionRecorder.videosDirectory.appendingPathComponent(name))
            }
        }
    }

    /// 최신 세션부터, 세션별로 묶어서 반환한다.
    var sessions: [(sessionID: UUID, records: [SwingRecord])] {
        var order: [UUID] = []
        var groups: [UUID: [SwingRecord]] = [:]
        for record in records {
            if groups[record.sessionID] == nil { order.append(record.sessionID) }
            groups[record.sessionID, default: []].append(record)
        }
        return order.reversed().map { ($0, groups[$0] ?? []) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([SwingRecord].self, from: data)) ?? []
    }

    private func save() {
        let snapshot = records
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
