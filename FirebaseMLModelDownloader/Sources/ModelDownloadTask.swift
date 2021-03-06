// Copyright 2021 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import FirebaseCore

/// Possible states of model downloading.
enum ModelDownloadStatus {
  case ready
  case downloading
  case complete
}

/// Download error codes.
enum ModelDownloadErrorCode {
  case noError
  case urlExpired
  case noConnection
  case downloadFailed
  case httpError(code: Int)
}

/// Manager to handle model downloading device and storing downloaded model info to persistent storage.
class ModelDownloadTask: NSObject {
  typealias ProgressHandler = (Float) -> Void
  typealias Completion = (Result<CustomModel, DownloadError>) -> Void

  /// Name of the app associated with this instance of ModelDownloadTask.
  private let appName: String
  /// Model info downloaded from server.
  private(set) var remoteModelInfo: RemoteModelInfo
  /// User defaults to which local model info should ultimately be written.
  private let defaults: UserDefaults
  /// Keeps track of download associated with this model download task.
  private(set) var downloadStatus: ModelDownloadStatus = .ready
  /// Downloader instance.
  private let downloader: FileDownloader
  /// Telemetry logger.
  private let telemetryLogger: TelemetryLogger?
  /// Progress handler.
  private var progressHandler: ProgressHandler?
  /// Completion.
  private var completion: Completion

  init(remoteModelInfo: RemoteModelInfo,
       appName: String,
       defaults: UserDefaults,
       downloader: FileDownloader,
       progressHandler: ProgressHandler? = nil,
       completion: @escaping Completion,
       telemetryLogger: TelemetryLogger? = nil) {
    self.remoteModelInfo = remoteModelInfo
    self.appName = appName
    self.downloader = downloader
    self.progressHandler = progressHandler
    self.completion = completion
    self.telemetryLogger = telemetryLogger
    self.defaults = defaults
  }
}

extension ModelDownloadTask {
  /// Name for model file stored on device.
  var downloadedModelFileName: String {
    return "fbml_model__\(appName)__\(remoteModelInfo.name).tflite"
  }

  /// Check if downloading is not complete for merging requests.
  func canMergeRequests() -> Bool {
    return downloadStatus != .complete
  }

  /// Check if download task can be resumed.
  func canResume() -> Bool {
    return downloadStatus == .ready
  }

  /// Merge duplicate requests. This method is not thread-safe.
  func merge(newProgressHandler: ProgressHandler? = nil, newCompletion: @escaping Completion) {
    let originalProgressHandler = progressHandler
    progressHandler = { progress in
      originalProgressHandler?(progress)
      newProgressHandler?(progress)
    }
    let originalCompletion = completion
    completion = { result in
      originalCompletion(result)
      newCompletion(result)
    }
  }

  func resume() {
    /// Prevent multiple concurrent downloads.
    guard downloadStatus != .downloading else {
      DeviceLogger.logEvent(level: .debug,
                            message: ModelDownloadTask.ErrorDescription.anotherDownloadInProgress,
                            messageCode: .anotherDownloadInProgressError)
      telemetryLogger?.logModelDownloadEvent(eventName: .modelDownload,
                                             status: .failed,
                                             downloadErrorCode: .downloadFailed)
      return
    }
    downloadStatus = .downloading
    telemetryLogger?.logModelDownloadEvent(eventName: .modelDownload,
                                           status: .downloading,
                                           downloadErrorCode: .noError)
    downloader.downloadFile(with: remoteModelInfo.downloadURL,
                            progressHandler: { downloadedBytes, totalBytes in
                              /// Fraction of model file downloaded.
                              let calculatedProgress = Float(downloadedBytes) / Float(totalBytes)
                              self.progressHandler?(calculatedProgress)
                            }) { result in
      self.downloadStatus = .complete
      switch result {
      case let .success(response):
        DeviceLogger.logEvent(level: .debug,
                              message: ModelDownloadTask.DebugDescription
                                .receivedServerResponse,
                              messageCode: .validHTTPResponse)
        self.handleResponse(
          response: response.urlResponse,
          tempURL: response.fileURL,
          completion: self.completion
        )
      case let .failure(error):
        var downloadError: DownloadError
        switch error {
        case let FileDownloaderError.networkError(error):
          let description = ModelDownloadTask.ErrorDescription
            .invalidHostName(error.localizedDescription)
          downloadError = .internalError(description: description)
          DeviceLogger.logEvent(level: .debug,
                                message: description,
                                messageCode: .hostnameError)
          self.telemetryLogger?.logModelDownloadEvent(
            eventName: .modelDownload,
            status: .failed,
            downloadErrorCode: .noConnection
          )
        case FileDownloaderError.unexpectedResponseType:
          let description = ModelDownloadTask.ErrorDescription.invalidHTTPResponse
          downloadError = .internalError(description: description)
          DeviceLogger.logEvent(level: .debug,
                                message: description,
                                messageCode: .invalidHTTPResponse)
          self.telemetryLogger?.logModelDownloadEvent(
            eventName: .modelDownload,
            status: .failed,
            downloadErrorCode: .downloadFailed
          )
        default:
          let description = ModelDownloadTask.ErrorDescription.unknownDownloadError
          downloadError = .internalError(description: description)
          DeviceLogger.logEvent(level: .debug,
                                message: description,
                                messageCode: .modelDownloadError)
          self.telemetryLogger?.logModelDownloadEvent(
            eventName: .modelDownload,
            status: .failed,
            downloadErrorCode: .downloadFailed
          )
        }
        self.completion(.failure(downloadError))
      }
    }
  }

  /// Handle model download response.
  func handleResponse(response: HTTPURLResponse, tempURL: URL, completion: @escaping Completion) {
    guard (200 ..< 299).contains(response.statusCode) else {
      switch response.statusCode {
      /// Possible failure due to download URL expiry.
      case 400:
        let currentDateTime = Date()
        /// Check if download url has expired.
        guard currentDateTime > remoteModelInfo.urlExpiryTime else {
          DeviceLogger.logEvent(level: .debug,
                                message: ModelDownloadTask.ErrorDescription
                                  .invalidModelName(remoteModelInfo.name),
                                messageCode: .invalidModelName)
          telemetryLogger?.logModelDownloadEvent(
            eventName: .modelDownload,
            status: .failed,
            downloadErrorCode: .httpError(code: response.statusCode)
          )
          completion(.failure(.invalidArgument))
          return
        }
        DeviceLogger.logEvent(level: .debug,
                              message: ModelDownloadTask.ErrorDescription.expiredModelInfo,
                              messageCode: .expiredModelInfo)
        telemetryLogger?.logModelDownloadEvent(
          eventName: .modelDownload,
          status: .failed,
          downloadErrorCode: .urlExpired
        )
        completion(.failure(.expiredDownloadURL))
      case 401, 403:
        DeviceLogger.logEvent(level: .debug,
                              message: ModelDownloadTask.ErrorDescription.permissionDenied,
                              messageCode: .permissionDenied)
        telemetryLogger?.logModelDownloadEvent(
          eventName: .modelDownload,
          status: .failed,
          downloadErrorCode: .httpError(code: response.statusCode)
        )
        completion(.failure(.permissionDenied))
      case 404:
        DeviceLogger.logEvent(level: .debug,
                              message: ModelDownloadTask.ErrorDescription
                                .modelNotFound(remoteModelInfo.name),
                              messageCode: .modelNotFound)
        telemetryLogger?.logModelDownloadEvent(
          eventName: .modelDownload,
          status: .failed,
          downloadErrorCode: .httpError(code: response.statusCode)
        )
        completion(.failure(.notFound))
      default:
        let description = ModelDownloadTask.ErrorDescription
          .modelDownloadFailed(response.statusCode)
        DeviceLogger.logEvent(level: .debug,
                              message: description,
                              messageCode: .modelDownloadError)
        telemetryLogger?.logModelDownloadEvent(
          eventName: .modelDownload,
          status: .failed,
          downloadErrorCode: .httpError(code: response.statusCode)
        )
        completion(.failure(.internalError(description: description)))
      }
      return
    }

    let modelFileURL = ModelFileManager.getDownloadedModelFilePath(
      appName: appName,
      modelName: remoteModelInfo.name
    )

    do {
      try ModelFileManager.moveFile(
        at: tempURL,
        to: modelFileURL,
        size: Int64(remoteModelInfo.size)
      )
      DeviceLogger.logEvent(level: .debug,
                            message: ModelDownloadTask.DebugDescription.savedModelFile,
                            messageCode: .downloadedModelFileSaved)
      /// Generate local model info.
      let localModelInfo = LocalModelInfo(from: remoteModelInfo, path: modelFileURL.absoluteString)
      /// Write model to user defaults.
      localModelInfo.writeToDefaults(defaults, appName: appName)
      DeviceLogger.logEvent(level: .debug,
                            message: ModelDownloadTask.DebugDescription.savedLocalModelInfo,
                            messageCode: .downloadedModelInfoSaved)
      /// Build model from model info.
      let model = CustomModel(localModelInfo: localModelInfo)
      DeviceLogger.logEvent(level: .debug,
                            message: ModelDownloadTask.DebugDescription.modelDownloaded,
                            messageCode: .modelDownloaded)
      telemetryLogger?.logModelDownloadEvent(
        eventName: .modelDownload,
        status: .succeeded,
        model: model,
        downloadErrorCode: .noError
      )
      completion(.success(model))
    } catch let error as DownloadError {
      if error == .notEnoughSpace {
        DeviceLogger.logEvent(level: .debug,
                              message: ModelDownloadTask.ErrorDescription.notEnoughSpace,
                              messageCode: .notEnoughSpace)
      } else {
        DeviceLogger.logEvent(level: .debug,
                              message: ModelDownloadTask.ErrorDescription.saveModel,
                              messageCode: .downloadedModelSaveError)
      }
      telemetryLogger?.logModelDownloadEvent(eventName: .modelDownload,
                                             status: .succeeded,
                                             downloadErrorCode: .downloadFailed)
      completion(.failure(error))
      return
    } catch {
      DeviceLogger.logEvent(level: .debug,
                            message: ModelDownloadTask.ErrorDescription.saveModel,
                            messageCode: .downloadedModelSaveError)
      telemetryLogger?.logModelDownloadEvent(eventName: .modelDownload,
                                             status: .succeeded,
                                             downloadErrorCode: .downloadFailed)
      completion(.failure(.internalError(description: error.localizedDescription)))
      return
    }
  }
}

/// Possible error messages for model downloading.
extension ModelDownloadTask {
  /// Debug descriptions.
  private enum DebugDescription {
    static let savedModelFile = "Model file saved successfully to device."
    static let savedLocalModelInfo = "Downloaded model info saved successfully to user defaults."
    static let receivedServerResponse = "Received a valid response from download server."
    static let modelDownloaded = "Model download completed successfully."
  }

  /// Error descriptions.
  private enum ErrorDescription {
    static let invalidHostName = { (error: String) in
      "Unable to resolve hostname or connect to host: \(error)"
    }

    static let modelDownloadFailed = { (code: Int) in
      "Model download failed with HTTP error code: \(code)"
    }

    static let modelNotFound = { (name: String) in
      "No model found with name: \(name)"
    }

    static let invalidModelName = { (name: String) in
      "Invalid model name: \(name)"
    }

    static let sessionInvalidated = "Session invalidated due to failed pre-conditions."
    static let invalidHTTPResponse =
      "Could not get valid HTTP response for model downloading."
    static let unknownDownloadError = "Unable to download model due to unknown error."
    static let saveModel = "Unable to save downloaded remote model file."
    static let notEnoughSpace = "Not enough space on device."
    static let expiredModelInfo = "Unable to update expired model info."
    static let anotherDownloadInProgress = "Download already in progress."
    static let permissionDenied = "Invalid or missing permissions to download model."
  }
}
