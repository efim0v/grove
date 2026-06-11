import Foundation

public struct RawCommit: Sendable, Equatable {
    public let hash: String
    public let parents: [String]
    public let author: String
    public let date: Date
    public let refs: [String]
    public let subject: String

    public init(hash: String, parents: [String], author: String, date: Date,
                refs: [String], subject: String) {
        self.hash = hash
        self.parents = parents
        self.author = author
        self.date = date
        self.refs = refs
        self.subject = subject
    }
}

public struct CommitNode: Sendable, Equatable {
    public let hash: String
    public let parents: [String]
    public let author: String
    public let date: Date
    public let refs: [String]
    public let subject: String
    public let lane: Int

    public init(hash: String, parents: [String], author: String, date: Date,
                refs: [String], subject: String, lane: Int) {
        self.hash = hash
        self.parents = parents
        self.author = author
        self.date = date
        self.refs = refs
        self.subject = subject
        self.lane = lane
    }
}

/// Parses `git log --format=%H%x09%P%x09%an%x09%cI%x09%D%x09%s` output.
/// 6 tab-separated fields per line; parents space-separated; %D comma-split and
/// trimmed ("tag: x" kept verbatim, empty -> []); malformed lines are skipped.
func parseCommitLog(_ output: String) -> [RawCommit] {
    var commits: [RawCommit] = []
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let fields = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
        guard fields.count == 6 else { continue }
        let parents = fields[1].split(separator: " ").map(String.init)
        let refs: [String] = fields[4].isEmpty
            ? []
            : fields[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        commits.append(RawCommit(
            hash: String(fields[0]),
            parents: parents,
            author: String(fields[2]),
            date: gitISODate(String(fields[3])) ?? Date(timeIntervalSince1970: 0),
            refs: refs,
            subject: String(fields[5])
        ))
    }
    return commits
}

/// Pure lane layout. Active lanes hold the hash each lane expects next:
/// a node takes the first lane expecting its hash, else the first free (nil) lane,
/// else a new lane; after placing, its lane expects the first parent (nil if root),
/// extra parents are tracked in free/new lanes if not tracked yet, and any OTHER
/// lane still expecting this node's hash is closed (set to nil).
public func layoutLanes(_ raw: [RawCommit]) -> [CommitNode] {
    var lanes: [String?] = []
    var nodes: [CommitNode] = []
    nodes.reserveCapacity(raw.count)
    for commit in raw {
        let lane: Int
        if let expected = lanes.firstIndex(of: commit.hash) {
            lane = expected
        } else if let free = lanes.firstIndex(where: { $0 == nil }) {
            lane = free
        } else {
            lanes.append(nil)
            lane = lanes.count - 1
        }
        lanes[lane] = commit.parents.first
        for extra in commit.parents.dropFirst() where !lanes.contains(extra) {
            if let free = lanes.firstIndex(where: { $0 == nil }) {
                lanes[free] = extra
            } else {
                lanes.append(extra)
            }
        }
        for index in lanes.indices where index != lane && lanes[index] == commit.hash {
            lanes[index] = nil
        }
        nodes.append(CommitNode(
            hash: commit.hash,
            parents: commit.parents,
            author: commit.author,
            date: commit.date,
            refs: commit.refs,
            subject: commit.subject,
            lane: lane
        ))
    }
    return nodes
}
