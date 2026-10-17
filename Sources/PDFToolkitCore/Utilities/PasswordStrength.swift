import Foundation

/// A coarse, dependency-free password-strength rating for the Protect tool's meter.
///
/// This is a UX nudge, not a security guarantee: it steers people away from a trivially guessable
/// password (short, one character class) toward a longer, more varied one. It deliberately does no
/// dictionary or breach lookup — everything stays local and instant, matching the app's offline promise.
public enum PasswordStrength: Int, Comparable, CaseIterable {
    case empty
    case weak
    case fair
    case good
    case strong

    public static func < (lhs: PasswordStrength, rhs: PasswordStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Filled segments (0…4) for a four-segment meter; `empty` shows nothing.
    public var filledSegments: Int { max(0, rawValue) }

    /// The short word shown beside the meter. `empty` has none.
    public var label: String {
        switch self {
        case .empty: return ""
        case .weak: return "Weak"
        case .fair: return "Fair"
        case .good: return "Good"
        case .strong: return "Strong"
        }
    }
}

public enum PasswordStrengthEstimator {
    /// Rates `password` by length and character-class variety. The scoring is intentionally simple and
    /// monotonic: more length and more distinct classes never lower the rating, and a short
    /// single-class password (e.g. all lowercase, under 12 characters) is capped at `weak` so it can
    /// never read as acceptable.
    public static func estimate(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return .empty }

        let length = password.count
        var classes = 0
        if password.contains(where: \.isLowercase) { classes += 1 }
        if password.contains(where: \.isUppercase) { classes += 1 }
        if password.contains(where: \.isNumber) { classes += 1 }
        // Anything that isn't a letter or number — punctuation, symbols, spaces — counts as the
        // fourth class.
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }

        var score: Int
        switch length {
        case 0...5: score = 0
        case 6...7: score = 1
        case 8...11: score = 2
        case 12...15: score = 3
        default: score = 4
        }
        // Variety bonus: each class beyond the first adds a point.
        score += max(0, classes - 1)
        // A short, single-class password is guessable regardless of the length bucket it lands in.
        if classes <= 1 && length < 12 { score = min(score, 1) }
        // Very few distinct characters is low entropy no matter the length — "aaaaaaaaaaaa",
        // "121212", or a run of spaces would otherwise ride the length buckets up to Good. Cap it:
        // ≤2 distinct can't exceed weak, ≤4 can't exceed fair.
        let distinctCharacters = Set(password).count
        if distinctCharacters <= 2 {
            score = min(score, 1)
        } else if distinctCharacters <= 4 {
            score = min(score, 2)
        }

        switch score {
        case ...1: return .weak
        case 2...3: return .fair
        case 4...5: return .good
        default: return .strong
        }
    }
}
