import Foundation

/// A hybrid logical clock timestamp: wall-clock time plus a counter, so every
/// edit gets a unique, totally ordered timestamp even when devices' clocks
/// disagree. `nodeId` identifies the device and breaks any remaining ties.
///
/// Matches `Hlc` in packages/core/lib/src/hlc.dart exactly, including the
/// packed text form, which the server sorts and compares.
public struct HLC: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let millis: Int
    public let counter: Int
    public let nodeId: String

    public init(_ millis: Int, _ counter: Int, _ nodeId: String) {
        self.millis = millis
        self.counter = counter
        self.nodeId = nodeId
    }

    public static func zero(_ nodeId: String) -> HLC { HLC(0, 0, nodeId) }

    /// The timestamp for a new local edit.
    public func send(_ now: Int) -> HLC {
        now > millis ? HLC(now, 0, nodeId) : HLC(millis, counter + 1, nodeId)
    }

    /// How far ahead of this device's clock a received timestamp may be and
    /// still move the clock forward.
    public static let maxDriftMillis = 24 * 60 * 60 * 1000

    /// Moves this clock past a timestamp from another device, so the next
    /// local edit is ordered after everything this device has seen.
    ///
    /// A timestamp more than `maxDriftMillis` ahead (a device whose date is
    /// set wrong) is still merged by the usual rule, but doesn't drag this
    /// clock into the future with it.
    public func receive(_ remote: HLC, _ now: Int) -> HLC {
        let remote = remote.millis - now > Self.maxDriftMillis ? self : remote
        let m = max(millis, remote.millis, now)
        let c: Int
        if m == millis && m == remote.millis {
            c = max(counter, remote.counter) + 1
        } else if m == millis {
            c = counter + 1
        } else if m == remote.millis {
            c = remote.counter + 1
        } else {
            c = 0
        }
        return HLC(m, c, nodeId)
    }

    public static func < (a: HLC, b: HLC) -> Bool {
        if a.millis != b.millis { return a.millis < b.millis }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.nodeId < b.nodeId
    }

    /// Text whose sort order matches the timestamps' order.
    public func pack() -> String {
        let m = String(millis)
        let c = String(counter, radix: 16)
        return String(repeating: "0", count: max(0, 15 - m.count)) + m + "-"
            + String(repeating: "0", count: max(0, 4 - c.count)) + c + "-" + nodeId
    }

    public static func parse(_ packed: String) -> HLC? {
        let parts = packed.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let m = Int(parts[0]), let c = Int(parts[1], radix: 16)
        else { return nil }
        return HLC(m, c, String(parts[2]))
    }

    public var description: String { pack() }
}

/// Field name that marks a row as deleted. Rows are never removed outright,
/// so a deletion syncs to other devices like any other edit.
public let deletedField = "_deleted"

/// One field-level edit: the unit of sync.
public struct Change: Codable, Hashable, Sendable {
    public let table: String
    public let rowId: String
    public let field: String
    public let value: JSONValue
    public let hlc: HLC

    public init(table: String, rowId: String, field: String, value: JSONValue, hlc: HLC) {
        self.table = table
        self.rowId = rowId
        self.field = field
        self.value = value
        self.hlc = hlc
    }

    enum CodingKeys: String, CodingKey { case table, rowId, field, value, hlc }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        table = try c.decode(String.self, forKey: .table)
        rowId = try c.decode(String.self, forKey: .rowId)
        field = try c.decode(String.self, forKey: .field)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        let packed = try c.decode(String.self, forKey: .hlc)
        guard let hlc = HLC.parse(packed) else {
            throw DecodingError.dataCorruptedError(
                forKey: .hlc, in: c, debugDescription: "Bad timestamp \(packed)")
        }
        self.hlc = hlc
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(table, forKey: .table)
        try c.encode(rowId, forKey: .rowId)
        try c.encode(field, forKey: .field)
        try c.encode(value, forKey: .value)
        try c.encode(hlc.pack(), forKey: .hlc)
    }
}

/// The merge rule every device and the server share: the latest write to a
/// field wins. Equal timestamps mean the same change arrived twice, so it's
/// ignored. Gives the same result in any order, any number of times.
public func shouldApply(_ incoming: HLC, over current: HLC?) -> Bool {
    guard let current else { return true }
    return incoming > current
}
