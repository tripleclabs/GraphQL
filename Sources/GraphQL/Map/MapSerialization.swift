import Foundation
import OrderedCollections

public struct MapSerialization {
    static func map(with object: NSObject) throws -> Map {
        switch object {
        case is NSNull:
            return .null
        case let number as NSNumber:
            // `_MapEncoder` boxes every scalar as an `NSNumber`, including
            // `Bool` (`box(_ value: Bool)`). Booleans are backed by CFBoolean,
            // so recover them here — otherwise a `Bool` becomes `.number`, whose
            // `Number(NSNumber)` initializer sets `storageType = .unknown`, and
            // `Map.encode` then writes it out via `doubleValue` as `0`/`1`.
            // `_MapDecoder.unbox(_:as: Bool.Type)` makes the same distinction.
            if isBoolean(number) {
                return .bool(number.boolValue)
            }
            return .number(Number(number))
        case let string as NSString:
            return .string(string as String)
        case let array as NSArray:
            let array: [Map] = try array.map { value in
                guard let value = value as? NSObject else {
                    throw EncodingError.invalidValue(
                        array,
                        EncodingError.Context(
                            codingPath: [],
                            debugDescription: "Array value was not an object: \(value) in \(array)"
                        )
                    )
                }
                return try self.map(with: value)
            }
            return .array(array)
        case let dictionary as NSDictionary:
            // Extract from an unordered dictionary, using NSDictionary extraction order
            let orderedDictionary: OrderedDictionary<String, Map> = try dictionary
                .reduce(into: [:]) { dictionary, pair in
                    guard let key = pair.key as? String else {
                        throw EncodingError.invalidValue(
                            dictionary,
                            EncodingError.Context(
                                codingPath: [],
                                debugDescription: "Dictionary key was not string: \(pair.key) in \(dictionary)"
                            )
                        )
                    }
                    guard let value = pair.value as? NSObject else {
                        throw EncodingError.invalidValue(
                            dictionary,
                            EncodingError.Context(
                                codingPath: [],
                                debugDescription: "Dictionary value was not an object: \(key) in \(dictionary)"
                            )
                        )
                    }
                    dictionary[key] = try self.map(with: value)
                }
            return .dictionary(orderedDictionary)
        default:
            throw EncodingError.invalidValue(
                object,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "Unable to encode the given top-level value to Map."
                )
            )
        }
    }

    /// Whether an `NSNumber` is really a boxed `Bool`. The bridging differs by
    /// platform, so this mirrors `_MapDecoder.unbox(_:as: Bool.Type)` exactly.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if DEPLOYMENT_RUNTIME_SWIFT || os(Linux) || os(Android)
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
            return number === kCFBooleanTrue as NSNumber || number === kCFBooleanFalse as NSNumber
        #endif
    }

    static func object(with map: Map) throws -> NSObject {
        switch map {
        case .undefined:
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "undefined values should have been excluded from serialization"
                )
            )
        case .null:
            return NSNull()
        case let .bool(value):
            return value as NSObject
        case var .number(number):
            return number.number
        case let .string(string):
            return string as NSString
        case let .array(array):
            return try array.map { try object(with: $0) } as NSArray
        case let .dictionary(dictionary):
            // Coerce to an unordered dictionary
            var unorderedDictionary: [String: NSObject] = [:]
            for (key, value) in dictionary {
                if !value.isUndefined {
                    try unorderedDictionary[key] = object(with: value)
                }
            }
            return unorderedDictionary as NSDictionary
        }
    }
}
