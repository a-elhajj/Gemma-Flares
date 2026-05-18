import Flutter
import UIKit
import Vision

final class LabTextRecognitionBridge: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  static let channelName = "com.gemma_flares/lab_ocr"

  private weak var presenter: UIViewController?
  private var pendingResult: FlutterResult?

  static func register(with messenger: FlutterBinaryMessenger, presenter: UIViewController) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let instance = LabTextRecognitionBridge(presenter: presenter)
    channel.setMethodCallHandler(instance.handle)
  }

  init(presenter: UIViewController) {
    self.presenter = presenter
    super.init()
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickImageAndRecognizeText":
      guard pendingResult == nil else {
        result(FlutterError(code: "ocr_busy", message: "OCR picker is already open.", details: nil))
        return
      }
      let args = call.arguments as? [String: Any]
      let wantsCamera = args?["camera"] as? Bool ?? false
      presentPicker(camera: wantsCamera, result: result)
    case "recognizeTextAtPath":
      guard pendingResult == nil else {
        result(FlutterError(code: "ocr_busy", message: "OCR is already running.", details: nil))
        return
      }
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "invalid_arguments", message: "recognizeTextAtPath requires 'path'.", details: nil))
        return
      }
      recognizeTextAtPath(path, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentPicker(camera: Bool, result: @escaping FlutterResult) {
    let source: UIImagePickerController.SourceType =
      camera && UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
    guard UIImagePickerController.isSourceTypeAvailable(source) else {
      result(["status": "unavailable", "text": "", "reason": "Image source is unavailable."])
      return
    }
    pendingResult = result
    let picker = UIImagePickerController()
    picker.sourceType = source
    picker.delegate = self
    picker.allowsEditing = false
    presenter?.present(picker, animated: true)
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true) { [weak self] in
      self?.pendingResult?(["status": "cancelled", "text": "", "reason": "User cancelled image selection."])
      self?.pendingResult = nil
    }
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
  ) {
    guard let image = info[.originalImage] as? UIImage, let cgImage = image.cgImage else {
      picker.dismiss(animated: true) { [weak self] in
        self?.pendingResult?(["status": "failed", "text": "", "reason": "Selected image could not be read."])
        self?.pendingResult = nil
      }
      return
    }

    picker.dismiss(animated: true) { [weak self] in
      self?.recognizeText(cgImage: cgImage)
    }
  }

  private func recognizeText(cgImage: CGImage) {
    let request = VNRecognizeTextRequest { [weak self] request, error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error {
          self.pendingResult?(["status": "failed", "text": "", "reason": error.localizedDescription])
          self.pendingResult = nil
          return
        }
        let observations = request.results as? [VNRecognizedTextObservation] ?? []
        let lines = observations.compactMap { observation in
          observation.topCandidates(1).first?.string
        }
        self.pendingResult?([
          "status": "success",
          "text": lines.joined(separator: "\n"),
          "reason": "vision_ocr_success",
        ])
        self.pendingResult = nil
      }
    }
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        try handler.perform([request])
      } catch {
        DispatchQueue.main.async {
          self?.pendingResult?(["status": "failed", "text": "", "reason": error.localizedDescription])
          self?.pendingResult = nil
        }
      }
    }
  }

  private func recognizeTextAtPath(_ path: String, result: @escaping FlutterResult) {
    guard let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage else {
      result(["status": "failed", "text": "", "reason": "Selected image could not be read."])
      return
    }
    pendingResult = result
    recognizeText(cgImage: cgImage)
  }
}
