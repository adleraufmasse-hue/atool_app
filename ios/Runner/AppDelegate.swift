import Flutter
import UniformTypeIdentifiers
import UIKit

private final class ShareFileItemSource: NSObject, UIActivityItemSource {
  private let fileUrl: URL

  init(fileUrl: URL) {
    self.fileUrl = fileUrl
  }

  func activityViewControllerPlaceholderItem(
    _ activityViewController: UIActivityViewController
  ) -> Any {
    return fileUrl
  }

  func activityViewController(
    _ activityViewController: UIActivityViewController,
    itemForActivityType activityType: UIActivity.ActivityType?
  ) -> Any? {
    return fileUrl
  }

  func activityViewController(
    _ activityViewController: UIActivityViewController,
    dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
  ) -> String {
    return UTType.data.identifier
  }

  func activityViewController(
    _ activityViewController: UIActivityViewController,
    subjectForActivityType activityType: UIActivity.ActivityType?
  ) -> String {
    return fileUrl.lastPathComponent
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate {
  private let downloadsChannel = "de.adleraufmasse.atool/downloads"
  private var pendingPickResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AToolDownloads") else {
      return
    }

    let channel = FlutterMethodChannel(
      name: downloadsChannel,
      binaryMessenger: registrar.messenger()
    )

    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "pickDownloadDirectory":
        self?.pickDownloadDirectory(result: result)
      case "saveFileToDirectory":
        self?.saveFileToDirectory(call: call, result: result)
      case "shareFile":
        self?.shareFile(call: call, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func pickDownloadDirectory(result: @escaping FlutterResult) {
    if pendingPickResult != nil {
      result(FlutterError(
        code: "PICKER_ACTIVE",
        message: "Ordnerauswahl läuft bereits.",
        details: nil
      ))
      return
    }

    pendingPickResult = result

    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [UTType.folder],
      asCopy: false
    )
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.shouldShowFileExtensions = true

    guard let presenter = topViewController() else {
      pendingPickResult = nil
      result(FlutterError(
        code: "NO_VIEW_CONTROLLER",
        message: "Ordnerauswahl konnte nicht geöffnet werden.",
        details: nil
      ))
      return
    }

    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPickResult?(nil)
    pendingPickResult = nil
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let result = pendingPickResult else { return }
    pendingPickResult = nil

    guard let url = urls.first else {
      result(nil)
      return
    }

    let didStartAccessing = url.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }

    do {
      let bookmarkData = try url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )

      result([
        "bookmark": "ios-bookmark://\(bookmarkData.base64EncodedString())",
        "name": url.lastPathComponent.isEmpty ? "Ausgewählter Ordner" : url.lastPathComponent,
      ])
    } catch {
      result(FlutterError(
        code: "BOOKMARK_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func saveFileToDirectory(call: FlutterMethodCall, result: FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let bookmarkValue = arguments["directoryUri"] as? String,
      let fileName = arguments["fileName"] as? String,
      let typedBytes = arguments["bytes"] as? FlutterStandardTypedData
    else {
      result(FlutterError(
        code: "INVALID_ARGUMENTS",
        message: "Download-Daten sind unvollständig.",
        details: nil
      ))
      return
    }

    let base64 = bookmarkValue.replacingOccurrences(of: "ios-bookmark://", with: "")

    guard let bookmarkData = Data(base64Encoded: base64) else {
      result(FlutterError(
        code: "INVALID_BOOKMARK",
        message: "Gespeicherter Ordnerzugriff ist ungültig.",
        details: nil
      ))
      return
    }

    var isStale = false

    do {
      let directoryUrl = try URL(
        resolvingBookmarkData: bookmarkData,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )

      let didStartAccessing = directoryUrl.startAccessingSecurityScopedResource()
      defer {
        if didStartAccessing {
          directoryUrl.stopAccessingSecurityScopedResource()
        }
      }

      let destinationUrl = directoryUrl.appendingPathComponent(fileName, isDirectory: false)

      if FileManager.default.fileExists(atPath: destinationUrl.path) {
        try FileManager.default.removeItem(at: destinationUrl)
      }

      try typedBytes.data.write(to: destinationUrl, options: .atomic)
      result(true)
    } catch {
      result(FlutterError(
        code: "SAVE_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func shareFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let arguments = call.arguments as? [String: Any],
      let fileName = arguments["fileName"] as? String,
      let typedBytes = arguments["bytes"] as? FlutterStandardTypedData
    else {
      result(FlutterError(
        code: "INVALID_ARGUMENTS",
        message: "Die zu teilende Datei ist unvollstaendig.",
        details: nil
      ))
      return
    }

    guard let presenter = topViewController() else {
      result(FlutterError(
        code: "NO_VIEW_CONTROLLER",
        message: "Das Teilen-Menue konnte nicht geoeffnet werden.",
        details: nil
      ))
      return
    }

    let shareDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("AToolShare", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileUrl = shareDirectory.appendingPathComponent(fileName, isDirectory: false)

    do {
      try FileManager.default.createDirectory(
        at: shareDirectory,
        withIntermediateDirectories: true
      )
      try typedBytes.data.write(to: fileUrl, options: .atomic)
    } catch {
      try? FileManager.default.removeItem(at: shareDirectory)
      result(FlutterError(
        code: "SHARE_FILE_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
      return
    }

    let activityController = UIActivityViewController(
      activityItems: [ShareFileItemSource(fileUrl: fileUrl)],
      applicationActivities: nil
    )
    activityController.popoverPresentationController?.sourceView = presenter.view
    activityController.popoverPresentationController?.sourceRect = CGRect(
      x: presenter.view.bounds.midX,
      y: presenter.view.bounds.midY,
      width: 1,
      height: 1
    )
    activityController.completionWithItemsHandler = {
      _, completed, _, activityError in
      try? FileManager.default.removeItem(at: shareDirectory)

      if let activityError {
        result(FlutterError(
          code: "SHARE_FAILED",
          message: activityError.localizedDescription,
          details: nil
        ))
      } else {
        result(completed)
      }
    }

    presenter.present(activityController, animated: true)
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }

    let rootViewController = scenes
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .rootViewController

    var top = rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }

    return top
  }
}
