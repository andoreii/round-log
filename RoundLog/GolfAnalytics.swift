import Foundation

struct GolfRate: Equatable, Sendable {
    var count: Int
    var recorded: Int
    var eligible: Int
    var value: Double? { recorded == 0 ? nil : Double(count) / Double(recorded) }
}

struct GolfRecordedTotal: Equatable, Sendable {
    var total: Int?
    var recorded: Int
    var eligible: Int
    var average: Double? { recorded == 0 ? nil : Double(total ?? 0) / Double(recorded) }
}

struct GolfRoundSummary: Equatable, Sendable {
    var roundID: UUID
    var holesPlayed: Int
    var totalStrokes: Int?
    var scoreToPar: Int?
    var putting: GolfRecordedTotal
    var threePutts: GolfRate
    var penalties: GolfRecordedTotal
    var penalizedHoles: GolfRate
    var fairways: GolfRate
    var approaches: GolfRate
    // Keys are strokes minus par, so unusual scores remain visible.
    var scoreDistribution: [Int: Int]
}

enum GolfShotKind: String, Sendable { case tee, approach }

struct GolfShotObservation: Equatable, Sendable {
    var roundID: UUID
    var holeNumber: Int
    var kind: GolfShotKind
    var club: String?
    var outcome: GolfOutcome?
    var distanceMetres: Decimal?
}

struct GolfClubBreakdown: Equatable, Sendable {
    var kind: GolfShotKind
    var club: String?
    var observations: Int
    var outcomes: [GolfOutcome: Int]
    var distanceSample: Int
    // Distance before an approach, never club carry or miss distance.
    var averageApproachDistanceMetres: Decimal?
}

struct GolfAnalyticsGroup: Equatable, Sendable {
    var plannedHoles: Int
    var status: GolfRoundStatus
    var roundCount: Int
    var holesPlayed: Int
    var averageStrokes: Double?
    var averageScoreToPar: Double?
    var putting: GolfRecordedTotal
    var threePutts: GolfRate
    var penalties: GolfRecordedTotal
    var penalizedHoles: GolfRate
    var fairways: GolfRate
    var approaches: GolfRate
    var scoreDistribution: [Int: Int]
    var clubBreakdowns: [GolfClubBreakdown]
}

enum GolfAnalytics {
    // The caller supplies finished rounds; stars never change this window.
    static func latestTwenty(_ finishedRounds: [GolfRoundPayload]) -> [GolfRoundPayload] {
        var latest: [UUID: GolfRoundPayload] = [:]
        for round in finishedRounds where round.revision >= (latest[round.roundID]?.revision ?? 0) {
            latest[round.roundID] = round
        }
        return Array(latest.values.sorted(by: isMoreRecent).prefix(20))
    }

    static func isMoreRecent(_ left: GolfRoundPayload, _ right: GolfRoundPayload) -> Bool {
        if left.playedOn != right.playedOn { return left.playedOn > right.playedOn }
        let leftDate = GolfCodec.date(left.createdAt) ?? .distantPast
        let rightDate = GolfCodec.date(right.createdAt) ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return left.roundID.uuidString < right.roundID.uuidString
    }

    static func summary(_ round: GolfRoundPayload) -> GolfRoundSummary {
        let holes = round.holes.filter { $0.strokes != nil }
        let putts = holes.compactMap(\.putts)
        let penalties = holes.compactMap(\.penalties)
        let teeOutcomes = holes.filter { $0.par > 3 }.compactMap { $0.teeShot?.outcome }
        let approachOutcomes = holes.compactMap { $0.effectiveApproach?.outcome }
        let distribution = Dictionary(holes.map { (($0.strokes ?? 0) - $0.par, 1) }, uniquingKeysWith: +)
        return GolfRoundSummary(
            roundID: round.roundID, holesPlayed: holes.count,
            totalStrokes: holes.isEmpty ? nil : holes.reduce(0) { $0 + ($1.strokes ?? 0) },
            scoreToPar: holes.isEmpty ? nil : holes.reduce(0) { $0 + ($1.strokes ?? 0) - $1.par },
            putting: GolfRecordedTotal(total: putts.isEmpty ? nil : putts.reduce(0, +), recorded: putts.count, eligible: holes.count),
            threePutts: GolfRate(count: putts.filter { $0 >= 3 }.count, recorded: putts.count, eligible: holes.count),
            penalties: GolfRecordedTotal(total: penalties.isEmpty ? nil : penalties.reduce(0, +), recorded: penalties.count, eligible: holes.count),
            penalizedHoles: GolfRate(count: penalties.filter { $0 > 0 }.count, recorded: penalties.count, eligible: holes.count),
            fairways: GolfRate(count: teeOutcomes.filter { $0 == .hit }.count, recorded: teeOutcomes.count, eligible: holes.filter { $0.par > 3 }.count),
            approaches: GolfRate(count: approachOutcomes.filter { $0 == .hit }.count, recorded: approachOutcomes.count, eligible: holes.count),
            scoreDistribution: distribution)
    }

    static func shots(_ round: GolfRoundPayload) -> [GolfShotObservation] {
        var observations: [GolfShotObservation] = []
        for hole in round.holes where hole.strokes != nil {
            let candidates: [(GolfShotKind, GolfShot?)] = hole.par == 3
                ? [(.approach, hole.teeShot)] : [(.tee, hole.teeShot), (.approach, hole.approachShot)]
            for (kind, shot) in candidates {
                guard let shot, shot.hasObservation else { continue }
                let distance = kind == .approach ? shot.distance.flatMap { shot.distanceUnit?.metres($0) } : nil
                observations.append(GolfShotObservation(roundID: round.roundID, holeNumber: hole.number, kind: kind,
                                                       club: try? GolfClub.normalize(shot.club), outcome: shot.outcome, distanceMetres: distance))
            }
        }
        return observations
    }

    static func trends(_ finishedRounds: [GolfRoundPayload]) -> [GolfAnalyticsGroup] {
        let window = latestTwenty(finishedRounds)
        return [9, 18].flatMap { count in
            [GolfRoundStatus.completed, .partial].compactMap { status in
                let rounds = window.filter { $0.plannedHoles == count && $0.status == status }
                guard !rounds.isEmpty else { return nil }
                let summaries = rounds.map(summary)
                return GolfAnalyticsGroup(
                    plannedHoles: count, status: status, roundCount: rounds.count,
                    holesPlayed: summaries.reduce(0) { $0 + $1.holesPlayed },
                    averageStrokes: average(summaries.compactMap(\.totalStrokes)),
                    averageScoreToPar: average(summaries.compactMap(\.scoreToPar)),
                    putting: combine(summaries.map(\.putting)), threePutts: combine(summaries.map(\.threePutts)),
                    penalties: combine(summaries.map(\.penalties)), penalizedHoles: combine(summaries.map(\.penalizedHoles)),
                    fairways: combine(summaries.map(\.fairways)), approaches: combine(summaries.map(\.approaches)),
                    scoreDistribution: summaries.reduce(into: [:]) { result, summary in
                        result.merge(summary.scoreDistribution, uniquingKeysWith: +)
                    }, clubBreakdowns: breakdowns(rounds.flatMap(shots)))
            }
        }
    }

    private static func average(_ values: [Int]) -> Double? {
        values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
    }

    private static func combine(_ totals: [GolfRecordedTotal]) -> GolfRecordedTotal {
        let recorded = totals.reduce(0) { $0 + $1.recorded }
        return GolfRecordedTotal(total: recorded == 0 ? nil : totals.reduce(0) { $0 + ($1.total ?? 0) },
                                 recorded: recorded, eligible: totals.reduce(0) { $0 + $1.eligible })
    }

    private static func combine(_ rates: [GolfRate]) -> GolfRate {
        GolfRate(count: rates.reduce(0) { $0 + $1.count }, recorded: rates.reduce(0) { $0 + $1.recorded },
                 eligible: rates.reduce(0) { $0 + $1.eligible })
    }

    private static func breakdowns(_ observations: [GolfShotObservation]) -> [GolfClubBreakdown] {
        let grouped = Dictionary(grouping: observations) { $0.kind.rawValue + ":" + ($0.club ?? "") }
        return grouped.keys.sorted().compactMap { key in
            guard let items = grouped[key], let first = items.first else { return nil }
            let distances = items.compactMap(\.distanceMetres)
            return GolfClubBreakdown(kind: first.kind, club: first.club, observations: items.count,
                                     outcomes: Dictionary(items.compactMap(\.outcome).map { ($0, 1) }, uniquingKeysWith: +),
                                     distanceSample: distances.count,
                                     averageApproachDistanceMetres: distances.isEmpty ? nil : distances.reduce(0, +) / Decimal(distances.count))
        }
    }
}
