//
//  Copyright © 2019 xcodereleases.com
//  MIT license - see LICENSE.md
//

import Rainbow
import Combine
import Foundation
import OlympUs
import XCIFoundation

enum DownloadError: Error {
    case authenticationError
    case listUpdateError
}

class Downloader {
    private var disposeBag = Set<AnyCancellable>()
    private let unauthorizedURL = URL(string: "https://developer.apple.com/unauthorized/")!
    private let logger: Logger
    private let olymp: OlympUs
    private let sessionDelegateProxy: URLSessionDelegateProxy

    init(logger: Logger, olymp: OlympUs, sessionDelegateProxy: URLSessionDelegateProxy) {
        self.logger = logger
        self.olymp = olymp
        self.sessionDelegateProxy = sessionDelegateProxy
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.zeroPadsFractionDigits = true
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "jms", options: 0, locale: nil)
        return formatter
    }()

    public func start(url: URL, disableSleep: Bool, concurrent: Int, resumeData: Data? = nil) -> Future<URL, XCAPIError> {
        var progressDisplay = ProgressDisplay(ratio: 0, width: 20)

        return Future { promise in
            let task: URLSessionDownloadTask
            if let resumeData = resumeData {
                task = self.olymp.session.downloadTask(withResumeData: resumeData)
            } else {
                var request = URLRequest(url: url)
                request.addValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
                request.addValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")

                task = self.olymp.session.downloadTask(with: request)
            }

            let download = MultiPartsDownloadTask(from: url, in: self.olymp.session,
                                        concurrent: concurrent,
                                        delegateProxy: self.sessionDelegateProxy,
                                        logger: self.logger,
                                        disableSleep: disableSleep)

            if resumeData == nil {
                self.logger.verbose("[\(Self.dateFormatter.string(from: Date()))] Starting download")
            } else {
                self.logger.verbose("[\(Self.dateFormatter.string(from: Date()))] Resuming download")
            }

            self.logger.log("Source: \(url)")
            var hasLoggedTotalSize = false
            var previouslyDisplayedNonANSIProgress = -1

            download.objectDidChange
                .throttle(for: 1, scheduler: RunLoop.main, latest: true)
                .sink {
                    switch download.state {
                    case .downloading:
                        if !hasLoggedTotalSize {
                            self.logger.log("Source: \(url) (\(Self.byteCountFormatter.string(from: download.totalBytes)))\n", onSameLine: true)
                            hasLoggedTotalSize = true
                        }
                        if Rainbow.enabled {
                            progressDisplay.ratio = download.progress
                            let logMessage = [
                                progressDisplay.representation,
                                "remaining: \(Self.byteCountFormatter.string(from: download.remainingBytes))",
                                "speed: \(Self.byteCountFormatter.string(from: download.downloadSpeed()))/s",
                            ].joined(separator: ", ")
                            self.logger.log(logMessage, onSameLine: true)
                        } else {
                            let progress = Int(100 * download.progress)
                            print(String(format: "%.1f %", 100 * download.progress))
                            if progress.isMultiple(of: 5), previouslyDisplayedNonANSIProgress != progress {
                                self.logger.log("Download progress: \(progress) %")
                                previouslyDisplayedNonANSIProgress = progress
                            }
                        }
                    case .finished:
                        if Rainbow.enabled {
                            progressDisplay.ratio = 1
                            let logMessage = [
                                progressDisplay.representation,
                                "remaining: \(Self.byteCountFormatter.string(from: Measurement(value: 0, unit: .bytes)))",
                                "speed: \(Self.byteCountFormatter.string(from: download.downloadSpeed()))/s",
                            ].joined(separator: ", ")
                            self.logger.log(logMessage, onSameLine: true)
                        } else {
                            self.logger.log("Download progress: 100 %")
                        }

                        self.sessionDelegateProxy.remove(proxy: download)

                        guard let downloadedURL = download.downloadedURL else {
                            promise(.failure(.couldNotMoveToTemporaryFile))
                            return
                        }
                        promise(.success(downloadedURL))
                    case .failed:
                        self.sessionDelegateProxy.remove(proxy: download)

                        switch (download.downloadedURL, download.resumeData) {
                        case let (nil, resumeData?) where download.isCancelled:
                            self.saveResumeData(resumeData, for: url)
                            promise(.failure(.downloadInterrupted))
                        case let (nil, resumeData?):
                            promise(.failure(.recoverableDownloadError(url: url, resumeData: resumeData)))
                        case (nil, nil):
                            promise(.failure(.couldNotMoveToTemporaryFile))
                        case (.some, _):
                            promise(.failure(.downloadInterrupted))
                        }
                    }
                }
                .store(in: &self.disposeBag)
        }
    }

    public func cacheURL(for url: URL) -> URL? {
        guard
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("xcinfo")
        else {
            self.logger.error("Unable to save unfinished download")
            return nil
        }

        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false, attributes: nil)

        let fileName = url.appendingPathExtension("resume").lastPathComponent
        return cache.appendingPathComponent(fileName)
    }

    private func saveResumeData(_ resumeData: Data, for url: URL) {
        guard let targetURL = cacheURL(for: url) else {
            self.logger.error("Unable to save unfinished download")
            return
        }

        do {
            try resumeData.write(to: targetURL)
        } catch {
            self.logger.error("Unable to save unfinished download")
            self.logger.error(error.localizedDescription)
        }
    }

    public func removeCachedResumeData(for url: URL) {
        guard let cacheURL = cacheURL(for: url) else {
            return
        }

        try? FileManager.default.removeItem(at: cacheURL)
    }

    var assets: OlympUs.AuthenticationAssets!

    public func authenticate(username: String, password: String) -> Future<Void, DownloadError> {
        Future { [weak self] promise in
            guard let self = self else { return }
            self.olymp.validateSession(for: username)
                .catch { _ in
                    self.olymp.getServiceKey(for: username)
                        .flatMap { serviceKey in
                            self.olymp.signIn(
                                accountName: username,
                                password: password,
                                serviceKey: serviceKey
                            )
                        }
                        .flatMap { authenticationAssets -> Future<ValidationType, OlympUsError> in
                            self.assets = authenticationAssets
                            return self.olymp.requestAuthentication(assets: self.assets)
                        }
                        .flatMap { validationType in
                            self.olymp.sendSecurityCode(validationType: validationType, assets: self.assets)
                        }
                        .flatMap { _ in
                            self.olymp.requestTrust(assets: self.assets)
                        }
                        .flatMap { _ in
                            self.olymp.getOlympusSession(assets: self.assets, for: username)
                        }
                }
                .flatMap { _ in
                    self.olymp.getDownloadAuth(assets: self.assets != nil ? self.assets : self.olymp.storedAuthenticationAssets(for: username)!)
                }
                .sink(receiveCompletion: { _ in
                    promise(.failure(.authenticationError))
                }, receiveValue: { _ in
                    promise(.success(()))
                })
                .store(in: &self.disposeBag)
        }
    }
}
