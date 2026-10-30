import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

/// Delivers address text once. The parent validates it, fills its review form, and dismisses.
@MainActor struct PairingScannerView: View {
    let onScan: (String) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraReady = false
    @State private var cameraMessage = "Checking camera availability…"
    @State private var cameraDenied = false
    @State private var input = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var readingPhoto = false
    @State private var importMessage: String?
    @State private var delivered = false

    init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if cameraReady && !delivered {
                        CameraQRScanner(onScan: deliver, onUnavailable: {
                            cameraReady = false
                            cameraMessage = "The camera is unavailable. Paste a connection code or import a QR image."
                        })
                        .frame(height: 280)
                        .accessibilityLabel("QR connection code camera")
                    } else {
                        Label(cameraMessage, systemImage: "qrcode.viewfinder")
                        if cameraDenied {
                            Button("Open Camera Settings") {
                                if let settings = URL(string: UIApplication.openSettingsURLString) { openURL(settings) }
                            }
                        }
                    }
                } footer: {
                    Text("Scan a Hermes server address. You’ll review it before connecting.")
                }

                Section("Paste or enter a connection code") {
                    TextField("HTTPS address or connection code", text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    PasteButton(payloadType: String.self) { strings in
                        if let value = strings.first { input = value }
                    }
                    Button("Review Address") { deliver(input) }
                        .disabled(input.isEmpty || delivered)
                }

                Section("QR image") {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Import QR Image", systemImage: "photo")
                    }
                    .disabled(readingPhoto || delivered)
                    if readingPhoto { ProgressView("Reading QR image…") }
                    if let importMessage { Text(importMessage).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Connect to Hermes")
            .task { await prepareCamera() }
            .task(id: selectedPhoto) { await readPhoto() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await prepareCamera() } }
            }
        }
    }

    private func deliver(_ value: String) {
        guard !delivered, !value.isEmpty else { return }
        delivered = true
        cameraReady = false
        onScan(value)
    }

    private func prepareCamera() async {
        guard !delivered else { return }
        guard DataScannerViewController.isSupported else {
            cameraMessage = "Live scanning isn’t available on this device or Simulator. Paste a connection code or import a QR image."
            return
        }
        var status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard !Task.isCancelled, !delivered else { return }
        cameraDenied = status == .denied
        cameraReady = status == .authorized && DataScannerViewController.isAvailable
        if !cameraReady {
            cameraMessage = "Camera access is unavailable. Paste a connection code or import a QR image."
        }
    }

    private func readPhoto() async {
        guard let photo = selectedPhoto, !delivered else { return }
        readingPhoto = true
        importMessage = nil
        defer {
            if selectedPhoto == photo {
                readingPhoto = false
                selectedPhoto = nil
            }
        }
        do {
            guard let data = try await photo.loadTransferable(type: Data.self), data.count <= 20 * 1_024 * 1_024 else {
                importMessage = "Choose a QR image smaller than 20 MB."
                return
            }
            let codes = try await Task.detached(priority: .userInitiated) { try Self.codes(in: data) }.value
            try Task.checkCancellation()
            if codes.count == 1, let code = codes.first { deliver(code) }
            else if codes.isEmpty { importMessage = "No QR code found. Try a clearer image or paste the address." }
            else { importMessage = "This image has several QR codes. Crop it to one connection code and try again." }
        } catch is CancellationError {
            return
        } catch {
            importMessage = "Couldn’t read this image. Try another image or paste the address."
        }
    }

    nonisolated private static func codes(in data: Data) throws -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048
              ] as CFDictionary) else { return [] }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return Array(Set((request.results ?? []).compactMap(\.payloadStringValue)))
    }
}

@MainActor private struct CameraQRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onUnavailable: onUnavailable) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() }
        catch { Task { @MainActor in onUnavailable() } }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        let onUnavailable: () -> Void
        private var delivered = false

        init(onScan: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onScan = onScan
            self.onUnavailable = onUnavailable
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for case .barcode(let barcode) in addedItems {
                guard let value = barcode.payloadStringValue, !value.isEmpty else { continue }
                delivered = true
                scanner.stopScanning()
                onScan(value)
                return
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            scanner.stopScanning()
            onUnavailable()
        }
    }
}
