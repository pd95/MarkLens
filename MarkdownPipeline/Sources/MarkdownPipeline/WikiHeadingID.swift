import Foundation

enum WikiHeadingID {
    static func slug(from text: String) -> String {
        var slug = ""
        var needsDash = false

        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if needsDash && slug.isEmpty == false {
                    slug.append("-")
                }
                needsDash = false
                slug.append(Character(scalar))
            } else {
                needsDash = true
            }
        }

        return slug.isEmpty ? "section" : slug
    }
}
