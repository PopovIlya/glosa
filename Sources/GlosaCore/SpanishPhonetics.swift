import Foundation

/// Spanish pronunciation from spelling: written syllables, stressed syllable, IPA (peninsular) and a
/// reading in Russian letters. Spanish spelling is regular enough for rules to be exact on ordinary words.
public enum SpanishPhonetics {
    public struct Result: Equatable, Sendable {
        public var syllables: [String]
        public var stress: Int
        public var ipa: String
        public var ruPron: String
    }

    public static func analyze(_ word: String) -> Result {
        let units = tokenize(word.lowercased())
        guard units.contains(where: \.isVowel) else {
            return Result(syllables: [word], stress: 0, ipa: "", ruPron: "")
        }
        let syllableOf = syllabify(units)
        let count = (syllableOf.last ?? 0) + 1
        let stress = stressedSyllable(units, syllableOf: syllableOf, count: count)
        let sounds = phonemes(units, syllableOf: syllableOf)

        var syllables = Array(repeating: "", count: count)
        for (u, s) in zip(units, syllableOf) { syllables[s] += u.letters }

        var ipa = ""
        for s in 0..<count {
            if count > 1 { ipa += s == stress ? "ˈ" : (s > 0 ? "." : "") }
            ipa += sounds.filter { $0.syllable == s }.map(\.ipa).joined()
        }
        return Result(syllables: syllables, stress: stress, ipa: "/\(ipa)/",
                      ruPron: cyrillic(sounds, stress: count > 1 ? stress : nil))
    }

    /// The word with a written accent added so that it keeps its stress after something is attached:
    /// levanta + te → levántate, levantando + se → levantándose.
    public static func attach(_ suffix: String, to form: String) -> String {
        let before = analyze(form)
        let fromEnd = before.syllables.count - 1 - before.stress
        let joined = form + suffix
        let after = analyze(joined)
        let wanted = after.syllables.count - 1 - (fromEnd + analyze(suffix).syllables.count)
        guard wanted >= 0, wanted != after.stress, !joined.contains(where: { "áéíóú".contains($0) }) else { return joined }
        // Put the accent on the nucleus of the syllable that should stay stressed.
        var syllables = after.syllables
        let s = syllables[wanted]
        let strong = s.firstIndex { "aeo".contains($0) } ?? s.lastIndex { "iu".contains($0) }
        guard let i = strong else { return joined }
        let accented: [Character: Character] = ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú"]
        var chars = Array(s)
        let k = s.distance(from: s.startIndex, to: i)
        chars[k] = accented[chars[k]] ?? chars[k]
        syllables[wanted] = String(chars)
        return syllables.joined()
    }

    // MARK: Letters

    struct Unit {
        enum Kind { case vowel(strong: Bool), consonant }
        var letters: String
        var kind: Kind
        /// The sound-relevant letter: "a"…"u" for vowels (accent kept), a key like "ch", "qu", "g" for consonants.
        var key: String
        var isVowel: Bool { if case .vowel = kind { true } else { false } }
        var isStrong: Bool { if case .vowel(let s) = kind { s } else { false } }
    }

    static let strongVowels: Set<Character> = ["a", "e", "o", "á", "é", "ó", "í", "ú"]
    static let weakVowels: Set<Character> = ["i", "u", "ü"]

    static func tokenize(_ word: String) -> [Unit] {
        let c = Array(word.filter { $0.isLetter })
        var units: [Unit] = []
        var i = 0
        func at(_ k: Int) -> Character? { k < c.count ? c[k] : nil }
        while i < c.count {
            let ch = c[i], next = at(i + 1), after = at(i + 2)
            let frontVowel = after.map { "eéií".contains($0) } ?? false
            if ch == "c" && next == "h" { units.append(Unit(letters: "ch", kind: .consonant, key: "ch")); i += 2; continue }
            if ch == "l" && next == "l" { units.append(Unit(letters: "ll", kind: .consonant, key: "ll")); i += 2; continue }
            if ch == "r" && next == "r" { units.append(Unit(letters: "rr", kind: .consonant, key: "rr")); i += 2; continue }
            if ch == "q" && next == "u" { units.append(Unit(letters: "qu", kind: .consonant, key: "qu")); i += 2; continue }
            if ch == "g" && next == "u" && frontVowel { units.append(Unit(letters: "gu", kind: .consonant, key: "gu")); i += 2; continue }
            if strongVowels.contains(ch) {
                units.append(Unit(letters: String(ch), kind: .vowel(strong: true), key: String(ch)))
            } else if weakVowels.contains(ch) {
                units.append(Unit(letters: String(ch), kind: .vowel(strong: false), key: ch == "ü" ? "u" : String(ch)))
            } else if ch == "y" {
                // A vowel at the end after a vowel (hoy, muy) or on its own (y); otherwise a consonant (yo, playa).
                let prevVowel = units.last?.isVowel ?? false
                let isVowel = c.count == 1 || (next == nil && prevVowel)
                units.append(Unit(letters: "y", kind: isVowel ? .vowel(strong: false) : .consonant, key: isVowel ? "i" : "y"))
            } else {
                units.append(Unit(letters: String(ch), kind: .consonant, key: String(ch)))
            }
            i += 1
        }
        return units
    }

    /// Consonant pairs that start a syllable together: pr, bl, tr…
    static func inseparable(_ a: Unit, _ b: Unit) -> Bool {
        ["p", "b", "f", "c", "k", "g", "t", "d", "v"].contains(a.key) && ["l", "r"].contains(b.key)
            && !(["t", "d"].contains(a.key) && b.key == "l")
    }

    /// Syllable index for every unit.
    static func syllabify(_ units: [Unit]) -> [Int] {
        // Nucleus groups: runs of vowels, split where two strong vowels meet (hiatus).
        var groups: [[Int]] = []
        var i = 0
        while i < units.count {
            guard units[i].isVowel else { i += 1; continue }
            var group = [i]
            var j = i + 1
            while j < units.count, units[j].isVowel {
                if units[j].isStrong && units[group.last!].isStrong { break }
                group.append(j)
                j += 1
            }
            groups.append(group)
            i = j
        }
        var syllableOf = Array(repeating: 0, count: units.count)
        for (g, group) in groups.enumerated() { for k in group { syllableOf[k] = g } }
        // Consonants before the first nucleus and after the last one.
        for k in 0..<groups[0][0] { syllableOf[k] = 0 }
        for k in (groups.last!.last! + 1)..<max(units.count, groups.last!.last! + 1) { syllableOf[k] = groups.count - 1 }
        // Consonants between nuclei.
        for g in 0..<(groups.count - 1) {
            let between = Array((groups[g].last! + 1)..<groups[g + 1][0])
            let toNext: Int
            switch between.count {
            case 0: toNext = 0
            case 1: toNext = 1
            case 2: toNext = inseparable(units[between[0]], units[between[1]]) ? 2 : 1
            case 3: toNext = inseparable(units[between[1]], units[between[2]]) ? 2 : 1
            default: toNext = 2
            }
            for (n, k) in between.enumerated() { syllableOf[k] = n < between.count - toNext ? g : g + 1 }
        }
        return syllableOf
    }

    static func stressedSyllable(_ units: [Unit], syllableOf: [Int], count: Int) -> Int {
        if let k = units.firstIndex(where: { u in u.letters.contains { "áéíóú".contains($0) } }) { return syllableOf[k] }
        guard count > 1, let last = units.last else { return 0 }
        let penultimate = last.isVowel && last.letters != "y" || ["n", "s"].contains(last.key)
        return penultimate ? count - 2 : count - 1
    }

    // MARK: Sounds

    struct Sound {
        var ipa: String
        var syllable: Int
        var isVowel = false
        var isNucleus = false
        var glide = false
    }

    static func phonemes(_ units: [Unit], syllableOf: [Int]) -> [Sound] {
        var sounds: [Sound] = []
        // Which vowel of each nucleus group carries the syllable; the others are glides j / w.
        var nucleus = Set<Int>()
        var k = 0
        while k < units.count {
            guard units[k].isVowel else { k += 1; continue }
            var group = [k]
            while let n = group.last.map({ $0 + 1 }), n < units.count, units[n].isVowel, syllableOf[n] == syllableOf[k] { group.append(n) }
            let candidates = group.filter { units[$0].letters != "y" }
            nucleus.insert(candidates.first { units[$0].isStrong } ?? candidates.last ?? group[0])
            k = group.last! + 1
        }
        func plain(_ s: String) -> String {
            ["á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ü": "u", "y": "i"][s] ?? s
        }
        for (i, u) in units.enumerated() {
            let prev = sounds.last?.ipa
            let next = i + 1 < units.count ? units[i + 1] : nil
            let initial = sounds.isEmpty
            let afterNasal = prev == "m" || prev == "n" || prev == "ŋ"
            var s = Sound(ipa: "", syllable: syllableOf[i])
            if u.isVowel {
                let v = plain(u.key == "i" && u.letters == "y" ? "i" : u.letters)
                if nucleus.contains(i) {
                    s.ipa = v; s.isVowel = true; s.isNucleus = true
                } else {
                    s.ipa = v == "i" ? "j" : "w"; s.glide = true
                }
            } else {
                let frontNext = next.map { $0.isVowel && "eéií".contains($0.letters) } ?? false
                switch u.key {
                case "b", "v": s.ipa = initial || afterNasal ? "b" : "β"
                case "d": s.ipa = initial || afterNasal || prev == "l" ? "d" : "ð"
                case "g": s.ipa = frontNext ? "x" : (initial || afterNasal ? "ɡ" : "ɣ")
                case "gu": s.ipa = initial || afterNasal ? "ɡ" : "ɣ"
                case "j": s.ipa = "x"
                case "c": s.ipa = frontNext ? "θ" : "k"
                case "z": s.ipa = "θ"
                case "qu", "k": s.ipa = "k"
                case "ch": s.ipa = "tʃ"
                case "ll", "y": s.ipa = "ʝ"
                case "ñ": s.ipa = "ɲ"
                case "x": s.ipa = "ks"
                case "h": s.ipa = ""
                case "rr": s.ipa = "r"
                case "r": s.ipa = initial || ["n", "l", "s"].contains(prev ?? "") ? "r" : "ɾ"
                case "n":
                    let n = next?.key ?? ""
                    s.ipa = ["b", "v", "p", "m"].contains(n) ? "m" : (["g", "j", "k", "qu"].contains(n) || (n == "c" && !(units.count > i + 2 && "eéií".contains(units[i + 2].letters))) ? "ŋ" : "n")
                case "w": s.ipa = "w"
                default: s.ipa = u.key
                }
            }
            if !s.ipa.isEmpty || u.isVowel { sounds.append(s) }
        }
        return sounds
    }

    static func cyrillic(_ sounds: [Sound], stress: Int?) -> String {
        let consonants: [String: String] = [
            "b": "б", "β": "б", "d": "д", "ð": "д", "ɡ": "г", "ɣ": "г", "x": "х", "θ": "с", "k": "к", "tʃ": "ч",
            "r": "р", "ɾ": "р", "l": "л", "m": "м", "n": "н", "ŋ": "н", "p": "п", "t": "т", "f": "ф", "s": "с",
            "ks": "кс",
        ]
        var out = ""
        var iotate = false           // next vowel is read with a j: я, е, ю…
        var afterConsonant = false
        var stressedDone = false
        for (i, s) in sounds.enumerated() {
            let nextIsVowel = i + 1 < sounds.count && sounds[i + 1].isVowel
            if s.isVowel {
                var v: String
                switch s.ipa {
                case "a": v = iotate ? "я" : "а"
                case "e": v = iotate ? "е" : (afterConsonant ? "е" : "э")
                case "i": v = "и"
                case "o": v = iotate ? (afterConsonant ? "о" : "йо") : "о"
                default: v = iotate ? "ю" : "у"
                }
                if let stress, s.syllable == stress, !stressedDone {
                    v = String(v.dropLast()) + String(v.last!) + "\u{301}"
                    stressedDone = true
                }
                out += v
                iotate = false
                afterConsonant = false
            } else if s.ipa == "j" || s.ipa == "ʝ" || s.ipa == "ɲ" {
                if s.ipa == "ɲ" { out += "н" }
                if nextIsVowel {
                    if afterConsonant || s.ipa == "ɲ" { out += "ь" }
                    iotate = true
                    afterConsonant = s.ipa == "ɲ" || afterConsonant
                } else {
                    out += s.ipa == "ɲ" ? "ь" : "й"
                    afterConsonant = false
                }
            } else if s.ipa == "w" {
                out += "у"
                afterConsonant = false
            } else {
                out += consonants[s.ipa] ?? s.ipa
                afterConsonant = true
            }
        }
        return out
    }
}
