#if os(macOS)
import Foundation

struct ReleaseVersion: Comparable, Equatable {
    private let components: [Int]
    private let prereleaseIdentifiers: [String]?

    func isInSameMinorRelease(as other: ReleaseVersion) -> Bool {
        components[0] == other.components[0]
            && (components.count > 1 ? components[1] : 0)
                == (other.components.count > 1 ? other.components[1] : 0)
    }

    var isPrerelease: Bool {
        prereleaseIdentifiers != nil
    }

    init?(_ value: String) {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first?.lowercased() == "v" {
            value.removeFirst()
        }

        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.isEmpty == false else {
            return nil
        }

        let numericParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let parsedComponents = numericParts.map { Int($0) }
        guard numericParts.isEmpty == false,
            numericParts.allSatisfy({ $0.isEmpty == false }),
            numericParts.allSatisfy({ $0.allSatisfy { $0.isNumber } }),
            parsedComponents.allSatisfy({ $0 != nil })
        else {
            return nil
        }
        var components = parsedComponents.compactMap { $0 }

        while components.count > 1 && components.last == 0 {
            components.removeLast()
        }

        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.isEmpty == false,
                identifiers.allSatisfy({ $0.isEmpty == false }),
                identifiers.allSatisfy({ identifier in
                    identifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                })
            else {
                return nil
            }
            prereleaseIdentifiers = identifiers.map(String.init)
        } else {
            prereleaseIdentifiers = nil
        }

        self.components = components
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }

        switch (lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (.some(let left), .some(let right)):
            for index in 0..<min(left.count, right.count) {
                if left[index] == right[index] {
                    continue
                }

                let leftNumber = Int(left[index])
                let rightNumber = Int(right[index])
                switch (leftNumber, rightNumber) {
                case (.some(let leftNumber), .some(let rightNumber)):
                    return leftNumber < rightNumber
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    if let leftParts = splitTrailingNumber(left[index]),
                        let rightParts = splitTrailingNumber(right[index]),
                        leftParts.prefix == rightParts.prefix,
                        leftParts.number != rightParts.number
                    {
                        return leftParts.number < rightParts.number
                    }
                    return left[index] < right[index]
                }
            }
            return left.count < right.count
        }
    }

    private static func splitTrailingNumber(_ value: String) -> (prefix: Substring, number: Int)? {
        guard let lastNonDigit = value.lastIndex(where: { $0.isNumber == false }) else {
            return nil
        }
        let digitStart = value.index(after: lastNonDigit)
        let digits = value[digitStart...]
        guard digitStart != value.endIndex,
            let number = Int(digits)
        else {
            return nil
        }
        return (value[..<digitStart], number)
    }
}

#endif
