/*
 This source file is part of the Swift.org open source project

 Copyright 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basic

/// Errors which may be encountered when running argument parser.
///
/// - unknown:            An unknown option is encountered.
/// - expectedValue:      Expected a value from the option.
/// - unexpectedArgument: An unexpected positional argument encountered.
/// - expectedArguments:  Expected these positional arguments but not found.
/// - typeMismatch:       The type of option's value doesn't match.
public enum ArgumentParserError: Swift.Error {
    case unknown(option: String)
    case expectedValue(option: String)
    case unexpectedArgument(String)
    case expectedArguments([String])
    case typeMismatch(String)
}

/// A protocol representing the possible types of arguments.
///
/// Conforming to this protocol will qualify the type to act as
/// positional and option arguments in the argument parser.
public protocol ArgumentKind {
    /// This will be called when the option is encountered while parsing.
    ///
    /// Call methods on the passed parser to manipulate parser as needed.
    init(parser: ArgumentParserProtocol) throws

    /// This will be called for positional arguments with the value discovered.
    init?(arg: String)
}

// MARK:- ArgumentKind conformance for common types

extension String: ArgumentKind {
    public init?(arg: String) {
        self = arg
    }

    public init(parser: ArgumentParserProtocol) throws {
        self = try parser.next()
    }
}

extension Int: ArgumentKind {
    public init?(arg: String) {
        self.init(arg)
    }

    public init(parser: ArgumentParserProtocol) throws {
        let arg = try parser.next()
        // Not every string can be converted into an integer.
        guard let intValue = Int(arg) else {
            throw ArgumentParserError.typeMismatch("\(arg) is not convertible to Int")
        }
        self = intValue
    }
}

extension Bool: ArgumentKind {
    public init?(arg: String) {
        self = true
    }

    public init(parser: ArgumentParserProtocol) throws {
        // We don't need to pop here because presence of the option
        // is enough to indicate that the bool value is true.
        self = true
    }
}

/// A protocol which implements ArgumentKind for string initializable enums.
///
/// Conforming to this protocol will automatically make an enum with is
/// String initializable conform to ArgumentKind.
public protocol StringEnumArgument: ArgumentKind {
    init?(rawValue: String)
}

extension StringEnumArgument {

    // FIXME: Hack because can not use init(arg:) in init(parser:)
    static func createObject(_ arg: String) -> Self? {
        return self.init(arg: arg)
    }

    public init(parser: ArgumentParserProtocol) throws {
        let arg = try parser.next()
        guard let obj = Self.createObject(arg) else {
            throw ArgumentParserError.unknown(option: arg)
        }
        self = obj
    }

    public init?(arg: String) {
        self.init(rawValue: arg)
    }
}


/// A protocol representing positional or options argument.
protocol ArgumentProtocol: Hashable {
    /// The argument kind of this argument for eg String, Bool etc.
    // FIXME: This should be constrained to ArgumentKind but Array can't conform to it:
    // `extension of type 'Array' with constraints cannot have an inheritance clause`.
    associatedtype ArgumentKindTy 

    /// Name of the argument which will be parsed by the parser.
    var name: String { get }

    /// Short name of the argument, this is usually used in options arguments
    /// for a short names for e.g: `--help` -> `-h`.
    var shortName: String? { get }

    /// The usage text associated with this argument. Used to generate complete help string.
    var usage: String? { get }
}

extension ArgumentProtocol {
    // MARK:- Conformance for Hashable

    public var hashValue: Int {
        return name.hashValue
    }

    public static func ==(_ lhs: Self, _ rhs: Self) -> Bool {
        return lhs.name == rhs.name && lhs.usage == rhs.usage
    }
}

/// Returns true if the given argument does not starts with '-' i.e. it is a positional argument,
/// otherwise it is an options argument.
fileprivate func isPositional(argument: String) -> Bool {
    return !argument.hasPrefix("-")
}

/// A class representing option arguments. These are optional arguments
/// which may or may not be provided in the command line. They are always
/// prefixed by their name. For e.g. --verbosity true.
public final class OptionArgument<Kind>: ArgumentProtocol {
    typealias ArgumentKindTy = Kind

    let name: String
    let usage: String?
    let shortName: String?

    init(name: String, shortName: String?, usage: String?) {
        precondition(!isPositional(argument: name))
        self.name = name
        self.shortName = shortName
        self.usage = usage
    }
}

/// A class representing positional arguments. These arguments must be present
/// and in the same order as they are added in the parser.
public final class PositionalArgument<Kind>: ArgumentProtocol {
    typealias ArgumentKindTy = Kind

    let name: String
    let usage: String?
    // Postional arguments don't need short names.
    var shortName: String? { return nil }

    init(name: String, usage: String?) {
        precondition(isPositional(argument: name))
        self.name = name
        self.usage = usage
    }
}

/// A type-erased argument.
///
/// Note: Only used for argument parsing purpose.
fileprivate final class AnyArgument: ArgumentProtocol {
    typealias ArgumentKindTy = Any

    let name: String
    let usage: String?
    let shortName: String?

    /// The argument kind this holds, used while initializing that argument.
    let kind: ArgumentKind.Type

    /// True if the argument kind is of array type.
    let isArray: Bool

    init<T: ArgumentProtocol>(_ arg: T) {
        self.kind = T.ArgumentKindTy.self as! ArgumentKind.Type
        self.name = arg.name
        self.shortName = arg.shortName
        self.usage = arg.usage
        isArray = false
    }

    /// Initializer for array arguments.
    init<T>(_ arg: OptionArgument<[T]>) {
        self.kind = T.self as! ArgumentKind.Type
        self.name = arg.name
        self.shortName = arg.shortName
        self.usage = arg.usage
        isArray = true
    }
}

/// Argument parser protocol passed in initializers of ArgumentKind to manipulate
/// parser as needed by the argument.
public protocol ArgumentParserProtocol {
    /// Provides next argument, if available.
    func next() throws -> String
}

/// Argument parser struct reponsible to parse the provided array of arguments and return
/// the parsed result.
public final class ArgumentParser: ArgumentParserProtocol {
    /// A struct representing result of the parsed arguments.
    public struct Result {
        /// Internal representation of arguments mapped to their values.
        private var results = [AnyArgument: Any]()

        /// Adds a result.
        ///
        /// - parameter
        ///     - argument: The argument for which this result is being added.
        ///     - value: The associated value of the argument.
        ///
        /// - throws: ArgumentParserError
        fileprivate mutating func addResult(for argument: AnyArgument, result: ArgumentKind) throws {
            if argument.isArray {
                var array = [ArgumentKind]()
                // Get the previously added results if present.
                if let previousResult = results[argument] as? [ArgumentKind] {
                    array = previousResult
                }
                array.append(result)
                results[argument] = array
            } else {
                results[argument] = result
            }
        }

        /// Get an option argument's value from the results.
        ///
        /// Since the options are optional, their result may or may not
        /// be present.
        public func get<T>(_ arg: OptionArgument<T>) -> T? {
            return results[AnyArgument(arg)] as? T
        }

        /// Array variant for option argument's get(_:).
        public func get<T>(_ arg: OptionArgument<[T]>) -> [T]? {
            return results[AnyArgument(arg)] as? [T]
        }

        /// Get a positional argument's value.
        public func get<T>(_ arg: PositionalArgument<T>) -> T {
            return results[AnyArgument(arg)] as! T
        }
    }


    /// List of arguments added to this parser.
    private var options = [AnyArgument]()
    private var positionalArgs = [AnyArgument]()

    // If provided, will be substituted instead of arg0 in usage text.
    let commandName: String?

    /// Usage string of this parser.
    let usage: String

    /// Overview text of this parser.
    let overview: String

    /// Create an argument parser.
    ///
    /// - Parameters:
    ///   - commandName: If provided, this will be substitued in "usage" line of the generated usage text.
    ///   Otherwise, first command line argument will be used.
    ///   - usage: The "usage" line of the generated usage text.
    ///   - overview: The "overview" line of the generated usage text.
    public init(commandName: String? = nil, usage: String, overview: String) {
        self.commandName = commandName
        self.usage = usage
        self.overview = overview
    }

    /// Adds an option to the parser.
    public func add<T: ArgumentKind>(option: String, shortName: String? = nil, kind: T.Type, usage: String? = nil) -> OptionArgument<T> {
        let arg = OptionArgument<T>(name: option, shortName: shortName, usage: usage)
        options.append(AnyArgument(arg))
        return arg
    }

    /// Adds an array argument type.
    public func add<T: ArgumentKind>(option: String, shortName: String? = nil, kind: [T].Type, usage: String? = nil) -> OptionArgument<[T]> {
        let arg = OptionArgument<[T]>(name: option, shortName: shortName, usage: usage)
        options.append(AnyArgument(arg))
        return arg
    }

    /// Adds an argument to the parser.
    public func add<T: ArgumentKind>(positional: String, kind: T.Type, usage: String? = nil) -> PositionalArgument<T> {
        let arg = PositionalArgument<T>(name: positional, usage: usage)
        positionalArgs.append(AnyArgument(arg))
        return arg
    }
    
    // MARK:- Parsing

    /// The iterator used to iterate arguments.
    private var argumentsIterator: IndexingIterator<[String]>!

    /// The current argument being parsed.
    private var currentArgument: String!

    /// Provides next argument from iterator or throws.
    public func next() throws -> String {
        guard let nextArg = argumentsIterator.next() else {
            throw ArgumentParserError.expectedValue(option: currentArgument)
        }
        return nextArg
    }

    /// Parses the provided array and return the result.
    public func parse(_ args: [String] = []) throws -> Result {
        var result = Result()
        // Create options map to quickly look up the arguments.
        let optionsTuple = options.flatMap { option -> [(String, AnyArgument)] in
            var result = [(option.name, option)]
            // Add the short names too, if we have them.
            if let shortName = option.shortName {
                result += [(shortName, option)]
            }
            return result
        }
        let optionsMap = Dictionary(items: optionsTuple)
        // Create iterators.
        var positionalArgsIterator = positionalArgs.makeIterator()
        argumentsIterator = args.makeIterator()

        while let arg = argumentsIterator.next() {
            // Store current argument.
            currentArgument = arg
            if isPositional(argument: arg) {
                // Get the next positional argument we are expecting.
                guard let positionalArg = positionalArgsIterator.next() else {
                    throw ArgumentParserError.unexpectedArgument(arg)
                }
                // Initialize the argument and add to result.
                guard let resultValue = positionalArg.kind.init(arg: arg) else {
                    throw ArgumentParserError.typeMismatch("\(arg) is not convertible to \(positionalArg.kind)")
                }
                try result.addResult(for: positionalArg, result: resultValue)
            } else {
                // Get the corresponding option for the option argument.
                guard let option = optionsMap[arg] else {
                    throw ArgumentParserError.unknown(option: arg)
                }
                // Initialize the argument and add to result.
                let resultValue = try option.kind.init(parser: self)
                try result.addResult(for: option, result: resultValue)
            }
        }
        // Report if there are any positional arguments which were not present in the arguments.
        let leftOverArgs = Array(positionalArgsIterator)
        guard leftOverArgs.isEmpty else {
            throw ArgumentParserError.expectedArguments(leftOverArgs.map {$0.name})
        }
        return result
    }

    /// Prints usage text for this parser on the provided stream.
    public func printUsage(on stream: OutputByteStream) {
        /// Space settings.
        let maxWidthDefault = 24
        let padding = 2

        let maxWidth: Int
        // Figure out the max width based on argument length or choose the default width if max width is longer
        // than the default width.
        if let maxArgument = (positionalArgs + options).map({ $0.name.characters.count }).max(), maxArgument < maxWidthDefault {
            maxWidth = maxArgument + padding + 1
        } else {
            maxWidth = maxWidthDefault
        }

        /// Returns a string of n spaces.
        func space(n: Int) -> String {
            guard n >= 0 else { return "" }
            var str = ""
            for _ in 0..<n {
                str += " "
            }
            return str
        }

        /// Prints an argument on a stream if it has usage.
        func print(formatted argument: AnyArgument, on stream: OutputByteStream) {
            // Don't do anything if we don't have usage for this argument.
            guard let usage = argument.usage else { return }
            // Start with a new line and add some padding.
            stream <<< "\n" <<< space(n: padding)
            let count = argument.name.characters.count
            // If the argument name is more than the set width take the whole
            // line for it, otherwise we can fit everything in one line.
            if count >= maxWidth - padding {
                stream <<< argument.name <<< "\n"
                // Align full width because we on a new line.
                stream <<< space(n: maxWidth + padding)
            } else {
                stream <<< argument.name
                // Align to the remaining empty space we have.
                stream <<< space(n: maxWidth - count)
            }
            stream <<< usage
        }

        stream <<< "OVERVIEW: " <<< overview <<< "\n\n"
        // Get the binary name from command line arguments.
        let defaultCommandName = CommandLine.arguments[0].components(separatedBy: "/").last!
        stream <<< "USAGE: " <<< (commandName ?? defaultCommandName) <<< " " <<< usage

        if positionalArgs.count > 0 {
            stream <<< "\n\n"
            stream <<< "COMMANDS:"
            for argument in positionalArgs {
                print(formatted: argument, on: stream)
            }
        }

        if options.count > 0 {
            stream <<< "\n\n"
            stream <<< "OPTIONS:"
            for argument in options {
                print(formatted: argument, on: stream)
            }
        }
    }
}
