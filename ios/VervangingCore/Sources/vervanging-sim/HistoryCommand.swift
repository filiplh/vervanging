import Foundation
import VervangingCore

// The history command and the history file of --history, ported from runHistory and readHistory in scripts/sim.mjs:
// the same checks, messages and JSON, byte for byte.

/// The names Node gives these errno values in `error.code` (libuv's names, which are the POSIX ones).
private let errnoNames: [Int32: String] = [
    EPERM: "EPERM", ENOENT: "ENOENT", EINTR: "EINTR", EIO: "EIO", ENXIO: "ENXIO", EBADF: "EBADF", ENOMEM: "ENOMEM",
    EACCES: "EACCES", EFAULT: "EFAULT", EBUSY: "EBUSY", EEXIST: "EEXIST", ENODEV: "ENODEV", ENOTDIR: "ENOTDIR",
    EISDIR: "EISDIR", EINVAL: "EINVAL", ENFILE: "ENFILE", EMFILE: "EMFILE", ETXTBSY: "ETXTBSY", EFBIG: "EFBIG",
    ENOSPC: "ENOSPC", EROFS: "EROFS", EAGAIN: "EAGAIN", ELOOP: "ELOOP", ENAMETOOLONG: "ENAMETOOLONG",
    EOVERFLOW: "EOVERFLOW", ETIMEDOUT: "ETIMEDOUT", ECANCELED: "ECANCELED",
]

private struct Errno: Error { let code: Int32 }

/// The whole file, read as `readFileSync(file)` reads it, or the errno of the failing call.
private func readFile(_ path: String) -> Result<Data, Errno> {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return .failure(Errno(code: errno)) }
    defer { close(fd) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count == 0 { return .success(data) }
        if count < 0 {
            if errno == EINTR { continue }
            return .failure(Errno(code: errno))
        }
        data.append(contentsOf: buffer[0..<count])
    }
}

/// Like `readHistory` in sim.mjs: the file read as UTF-8 (a byte that is not UTF-8 reads as U+FFFD, as in Node),
/// then JSON.parse and normaliseHistory.
/// ⚠ An errno missing from the table above shows as UNKNOWN; Node would name it. No example reaches one.
func readHistory(_ file: String) throws -> History {
    let data: Data
    switch readFile(file) {
    case .success(let read): data = read
    case .failure(let error):
        throw UsageError("cannot read the history file \"\(file)\" (\(errnoNames[error.code] ?? "UNKNOWN"))")
    }
    do {
        return try History(json: String(decoding: data, as: UTF8.self))
    } catch {
        throw UsageError("the history file \"\(file)\" is not valid JSON")
    }
}

/// The history command's output: JSON.stringify of `seasonSummary(readHistory(file))`.
func historyJSON(_ opts: [String: String]) throws -> String {
    guard let file = opts["history"] else { throw UsageError("--history <file> is required") }
    return try readHistory(file).seasonSummary().json
}
