import Testing
@testable import PDFToolkitCore

/// The password meter's estimator is a coarse UX nudge, but its ordering must be sane: empty reads as
/// empty, a short single-class password never rates above weak, and more length / more variety only
/// ever raises the rating.
@Suite struct PasswordStrengthTests {

    @Test func emptyIsEmpty() {
        #expect(PasswordStrengthEstimator.estimate("") == .empty)
    }

    @Test func shortSingleClassIsCappedAtWeak() {
        // Even a length that would otherwise bucket higher can't lift an all-lowercase, sub-12 password.
        #expect(PasswordStrengthEstimator.estimate("abc") == .weak)
        #expect(PasswordStrengthEstimator.estimate("abcdefghij") == .weak) // 10 lowercase
        #expect(PasswordStrengthEstimator.estimate("12345678") == .weak)   // 8 digits, one class
    }

    @Test func varietyAndLengthRaiseTheRating() {
        #expect(PasswordStrengthEstimator.estimate("Abcd12") == .fair)         // 6, three classes
        #expect(PasswordStrengthEstimator.estimate("Abcdef12") == .good)       // 8, three classes
        #expect(PasswordStrengthEstimator.estimate("Abcdef1!ghij") == .strong) // 12, four classes
    }

    @Test func lowDistinctCharacterCountIsCappedRegardlessOfLength() {
        // Length buckets alone would rate these Good/Fair; the distinct-character cap pulls them down.
        #expect(PasswordStrengthEstimator.estimate("aaaaaaaaaaaaaaaa") == .weak) // 16 identical
        #expect(PasswordStrengthEstimator.estimate("1212121212") == .weak)       // 2 distinct
        #expect(PasswordStrengthEstimator.estimate("            ") == .weak)      // 12 spaces, 1 distinct
        #expect(PasswordStrengthEstimator.estimate("Ab1!Ab1!Ab1!") == .fair)     // 4 distinct, repeated
    }

    @Test func aLongPassphraseRatesWellOnLengthAlone() {
        // Four+ words of lowercase clears the single-class cap purely on length (>= 12).
        #expect(PasswordStrengthEstimator.estimate("correcthorsebatterystaple") >= .good)
    }

    @Test func ratingIsMonotonicInLength() {
        // Growing a four-class string one character at a time must never lower the rating.
        let alphabet = "Ab1!Cd2@Ef3#Gh4$Ij5%Kl6^Mn7&Op8*"
        var previous = PasswordStrength.empty
        for count in 1...alphabet.count {
            let rating = PasswordStrengthEstimator.estimate(String(alphabet.prefix(count)))
            #expect(rating >= previous)
            previous = rating
        }
    }
}
