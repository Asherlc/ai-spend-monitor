import Foundation

public enum AppStorageLocation {
  public static let directoryName = "AISpendBar"
  public static let ledgerFilename = "AISpendBar.store"

  public static var defaultLedgerURL: URL {
    let applicationSupport =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support",
        isDirectory: true
      )

    let appDirectory = applicationSupport.appendingPathComponent(
      directoryName,
      isDirectory: true
    )
    return appDirectory.appendingPathComponent(
      ledgerFilename,
      isDirectory: false
    )
  }

  public static func prepareLedgerURL(
    fileManager: FileManager = .default
  ) throws -> URL {
    let url = defaultLedgerURL
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    return url
  }
}
