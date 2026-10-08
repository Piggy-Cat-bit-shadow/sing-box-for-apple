// `RemoteProfileFetcher.swift` names `HTTPClient.userAgent`, which in the app lives in the same
// `Library` module. In this package the fetch path is its own module and the two symbols it needs
// are in `AppStubs`, so they are re-exported here rather than by editing the file that ships -
// `RemoteProfileFetcher.swift` is a symlink and must stay byte-identical to the app's copy.

@_exported import AppStubs
