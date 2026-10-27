import Foundation
import GlosaCore

/// Canned answers for `--demo`: shows the panel without a key or network. Decks go to a temp folder.
struct DemoBackend: ClaudeBackend {
    var label: String { "демо" }

    static func prepare() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glosa-demo")
        setenv("GLOSA_VOCAB_ES", dir.appendingPathComponent("es.json").path, 1)
        setenv("GLOSA_VOCAB_EN", dir.appendingPathComponent("en.json").path, 1)
    }

    func complete(system: String, user: String, schema: String) async throws -> Data {
        try await Task.sleep(nanoseconds: 600_000_000)
        return Data((schema == Prompt.conjugationSchema ? Self.conjugation : Self.phrase).utf8)
    }

    static let phrase = """
    {"language":"es","kind":"phrase","translation":"Мы встаём очень рано","note":"levantarse — возвратный глагол: me levanto, te levantas…",
     "words":[
      {"word":"nos","lemma":"nos","pos":"pronoun","form":"","ipa":"/nos/","lemma_ipa":"","syllables":["nos"],"stress":0,"ru_pron":"нос","translation":"себя (нас)","alternatives":["нам","нас"],"is_function_word":true},
      {"word":"levantamos","lemma":"levantarse","pos":"verb","form":"1 л. мн. ч., presente","ipa":"/le.βanˈta.mos/","lemma_ipa":"/le.βanˈtaɾ.se/","syllables":["le","van","ta","mos"],"stress":2,"ru_pron":"левантáмос","translation":"встаём","alternatives":["подниматься","просыпаться"],"is_function_word":false},
      {"word":"muy","lemma":"muy","pos":"adverb","form":"","ipa":"/mui̯/","lemma_ipa":"","syllables":["muy"],"stress":0,"ru_pron":"му́й","translation":"очень","alternatives":[],"is_function_word":false},
      {"word":"temprano","lemma":"temprano","pos":"adverb","form":"","ipa":"/temˈpɾa.no/","lemma_ipa":"","syllables":["tem","pra","no"],"stress":1,"ru_pron":"темпра́но","translation":"рано","alternatives":["ранний"],"is_function_word":false}],
     "examples":[]}
    """

    static let conjugation = """
    {"infinitive":"levantarse","translation":"вставать","gerund":"levantándose","participle":"levantado","irregular":false,
     "tenses":[
      {"name":"Presente","ru":"настоящее","forms":[{"person":"yo","form":"me levanto"},{"person":"tú","form":"te levantas"},{"person":"él/ella/usted","form":"se levanta"},{"person":"nosotros","form":"nos levantamos"},{"person":"vosotros","form":"os levantáis"},{"person":"ellos/ellas/ustedes","form":"se levantan"}]},
      {"name":"Pretérito indefinido","ru":"простое прошедшее","forms":[{"person":"yo","form":"me levanté"},{"person":"tú","form":"te levantaste"},{"person":"él/ella/usted","form":"se levantó"},{"person":"nosotros","form":"nos levantamos"},{"person":"vosotros","form":"os levantasteis"},{"person":"ellos/ellas/ustedes","form":"se levantaron"}]}]}
    """
}
