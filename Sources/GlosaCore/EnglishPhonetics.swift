import Foundation

/// English pronunciation from CMUdict phones ("W EH1 N T"): IPA (American, as CMUdict is) with the
/// primary stress mark, a reading in Russian letters, and which vowel is stressed.
public enum EnglishPhonetics {
    public struct Result: Equatable, Sendable {
        public var ipa: String
        public var ruPron: String
        /// Number of vowels (syllables) and the index of the stressed one.
        public var vowels: Int
        public var stress: Int
    }

    static let vowelIPA: [String: (stressed: String, unstressed: String)] = [
        "AA": ("ɑ", "ɑ"), "AE": ("æ", "æ"), "AH": ("ʌ", "ə"), "AO": ("ɔ", "ɔ"), "AW": ("aʊ", "aʊ"), "AY": ("aɪ", "aɪ"),
        "EH": ("ɛ", "ɛ"), "ER": ("ɝ", "ɚ"), "EY": ("eɪ", "eɪ"), "IH": ("ɪ", "ɪ"), "IY": ("i", "i"), "OW": ("oʊ", "oʊ"),
        "OY": ("ɔɪ", "ɔɪ"), "UH": ("ʊ", "ʊ"), "UW": ("u", "u"),
    ]
    static let consonantIPA: [String: String] = [
        "B": "b", "CH": "tʃ", "D": "d", "DH": "ð", "F": "f", "G": "ɡ", "HH": "h", "JH": "dʒ", "K": "k", "L": "l",
        "M": "m", "N": "n", "NG": "ŋ", "P": "p", "R": "ɹ", "S": "s", "SH": "ʃ", "T": "t", "TH": "θ", "V": "v",
        "W": "w", "Y": "j", "Z": "z", "ZH": "ʒ",
    ]
    static let vowelRU: [String: (stressed: String, unstressed: String)] = [
        "AA": ("а", "а"), "AE": ("э", "э"), "AH": ("а", "э"), "AO": ("о", "о"), "AW": ("ау", "ау"), "AY": ("ай", "ай"),
        "EH": ("е", "е"), "ER": ("ёр", "эр"), "EY": ("ей", "ей"), "IH": ("и", "и"), "IY": ("и", "и"), "OW": ("оу", "оу"),
        "OY": ("ой", "ой"), "UH": ("у", "у"), "UW": ("у", "у"),
    ]
    static let consonantRU: [String: String] = [
        "B": "б", "CH": "ч", "D": "д", "DH": "з", "F": "ф", "G": "г", "HH": "х", "JH": "дж", "K": "к", "L": "л",
        "M": "м", "N": "н", "NG": "нг", "P": "п", "R": "р", "S": "с", "SH": "ш", "T": "т", "TH": "с", "V": "в",
        "W": "у", "Y": "й", "Z": "з", "ZH": "ж",
    ]
    /// Consonant clusters that begin an English syllable, so the stress mark goes before them (ˈstɹ…).
    static let onsets: Set<String> = [
        "P R", "P L", "B R", "B L", "T R", "D R", "K R", "K L", "G R", "G L", "F R", "F L", "TH R", "SH R",
        "S P", "S T", "S K", "S M", "S N", "S L", "S W", "T W", "K W", "D W", "P Y", "B Y", "K Y", "F Y", "M Y", "HH Y",
        "S P R", "S T R", "S K R", "S P L", "S K W",
    ]

    public static func analyze(_ phones: String) -> Result {
        let parts = phones.split(separator: " ").map(String.init)
        let base = parts.map { $0.filter(\.isLetter) }
        let vowelAt = parts.indices.filter { vowelIPA[base[$0]] != nil }
        let primary = parts.firstIndex { $0.hasSuffix("1") } ?? vowelAt.first ?? 0
        let stress = vowelAt.firstIndex(of: primary) ?? 0

        // The stress mark goes before the longest valid onset in front of the stressed vowel.
        var markAt = primary
        if vowelAt.count > 1 {
            let previousVowel = vowelAt.last { $0 < primary } ?? -1
            var start = primary
            while start - 1 > previousVowel {
                let cluster = base[(start - 1)..<primary].joined(separator: " ")
                if start - 1 == primary - 1 ? base[start - 1] != "NG" : onsets.contains(cluster) { start -= 1 } else { break }
            }
            markAt = start
        }

        var ipa = "", ru = ""
        var iotate = false
        for (i, p) in base.enumerated() {
            let stressed = parts[i].hasSuffix("1") || parts[i].hasSuffix("2")
            if vowelAt.count > 1 && i == markAt { ipa += "ˈ" }
            if let v = vowelIPA[p] {
                ipa += stressed ? v.stressed : v.unstressed
                var r = stressed ? vowelRU[p]!.stressed : vowelRU[p]!.unstressed
                if iotate {
                    r = ["а": "я", "у": "ю", "е": "е", "э": "е", "о": "ё"][String(r.first!)].map { $0 + r.dropFirst() } ?? r
                    iotate = false
                }
                if i == primary && vowelAt.count > 1 {
                    r = String(r.first!) + "\u{301}" + r.dropFirst()
                }
                ru += r
            } else {
                ipa += consonantIPA[p] ?? ""
                if p == "Y", i + 1 < base.count, vowelIPA[base[i + 1]] != nil {
                    iotate = true
                } else {
                    ru += consonantRU[p] ?? ""
                }
            }
        }
        return Result(ipa: "/\(ipa)/", ruPron: ru, vowels: vowelAt.count, stress: stress)
    }
}
