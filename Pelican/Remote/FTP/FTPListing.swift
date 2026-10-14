import Foundation

/// Turns directory listings into FileItems: MLSD where the server has it, `ls -l` text otherwise.
enum FTPListing {
    /// type=dir;modify=20261014142400;size=12; public_html
    static func mlsd(_ text: String, in folder: String) -> [FileItem] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let name = String(line[line.index(after: space)...])
            var facts: [String: String] = [:]
            for fact in line[..<space].split(separator: ";") {
                let pair = fact.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { facts[pair[0].lowercased()] = String(pair[1]) }
            }
            let type = facts["type"]?.lowercased() ?? "file"
            guard type != "cdir", type != "pdir", name != ".", name != ".." else { return nil }
            let isDirectory = type == "dir"
            return FileItem(name: name, path: join(folder, name), isDirectory: isDirectory,
                            size: isDirectory ? nil : facts["size"].flatMap { Int64($0) },
                            modified: facts["modify"].flatMap(parseMLSDTime))
        }
    }

    /// drwxr-xr-x  2 user group  4096 Oct 14 14:24 public_html
    static func unix(_ text: String, in folder: String, now: Date = .now) -> [FileItem] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9, let kind = fields[0].first, "-dl".contains(kind) else { return nil }
            var name = String(fields[8])
            if kind == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            guard name != ".", name != ".." else { return nil }
            let isDirectory = kind == "d"
            return FileItem(name: name, path: join(folder, name), isDirectory: isDirectory,
                            size: isDirectory ? nil : Int64(fields[4]),
                            modified: parseLsDate(String(fields[5]), String(fields[6]), String(fields[7]), now: now))
        }
    }

    private static func join(_ folder: String, _ name: String) -> String {
        (folder as NSString).appendingPathComponent(name)
    }

    private static func parseMLSDTime(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(value.prefix(14)))
    }

    /// "Oct 14 14:24" (this year, or last year if that would be in the future) or "Oct 14 2022".
    private static func parseLsDate(_ month: String, _ day: String, _ timeOrYear: String, now: Date) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        if timeOrYear.contains(":") {
            let year = Calendar.current.component(.year, from: now)
            formatter.dateFormat = "MMM d yyyy HH:mm"
            guard let date = formatter.date(from: "\(month) \(day) \(year) \(timeOrYear)") else { return nil }
            return date > now.addingTimeInterval(86_400)
                ? Calendar.current.date(byAdding: .year, value: -1, to: date) : date
        }
        formatter.dateFormat = "MMM d yyyy"
        return formatter.date(from: "\(month) \(day) \(timeOrYear)")
    }
}
