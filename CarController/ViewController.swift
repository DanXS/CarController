//
//  ViewController.swift
//  CarController
//
//  Created by Dan Shepherd on 05/03/2019.
//  Copyright © 2019 Dan Shepherd. All rights reserved.
//

import UIKit
import AVFoundation
import Photos
import GameController
import BLEControlFramework

class ViewController: UIViewController, BLESerialConnectionDelegate, BLEControlDelegate, AVCaptureFileOutputRecordingDelegate {

    
    
    
    @IBOutlet weak var cameraPreviewView: CameraPreviewView!
    @IBOutlet weak var electronicsImageView: UIImageView!
    @IBOutlet weak var joystickImageView: UIImageView!
    @IBOutlet weak var bluetoothImageView: UIImageView!
    @IBOutlet weak var stopPreviewButton: UIButton!
    @IBOutlet weak var recordToggleButton: UIButton!
    
    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
    private let session = AVCaptureSession()
    private var isSessionRunning = false
    private var isRecording = false
    private let sessionQueue = DispatchQueue(label: "session queue")
    private var setupResult: SessionSetupResult = .success
    private var movieFileOutput: AVCaptureMovieFileOutput? = nil
    private var backgroundRecordingID: UIBackgroundTaskIdentifier?
    @objc dynamic var videoDeviceInput: AVCaptureDeviceInput!
    
    private var serial : BLESerialConnection?
    private var peripherals : [(CBPeripheral, NSNumber)] = []
    private var selectedPeripheral : CBPeripheral? = nil
    private var bleConnected : Bool = false
    private var bleReady : Bool = false
    private var control : BLEControl? = nil
    private var gameController : GCController? = nil
    private var prevMotorSpeed : Float = 0.0
    private var prevSteering : Float = 0.0
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.bluetoothImageView.tintColor = UIColor.red
        self.joystickImageView.tintColor = UIColor.red
        self.electronicsImageView.tintColor = UIColor.red
        self.initCamera()
        self.serial = BLESerialConnection(delegate: self)
        guard self.serial != nil else {
            assert(false, "Could not instantiate BLESerialConnection class")
            return
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NotificationCenter.default.addObserver(self, selector: #selector(gameControllerDidConnect), name: NSNotification.Name.GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(gameControllerDidDisconnect), name: NSNotification.Name.GCControllerDidDisconnect, object: nil)
        self.initGameController()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        self.sessionQueue.async {
            if self.setupResult == .success {
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
                
            }
        }
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.GCControllerDidConnect, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.GCControllerDidDisconnect, object: nil)
        super.viewWillDisappear(animated)
    }
    
    // MARK: - Camera configuration
    
    private func initCamera() {
        self.cameraPreviewView.session = self.session
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera.
            break
            
        case .notDetermined:
            self.sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })
            
        default:
            // The user has previously denied access.
            self.setupResult = .notAuthorized
        }
        self.sessionQueue.async {
            self.configureSession()
        }
    }
    
    private func configureSession() {
        if setupResult != .success {
            return
        }
        
        session.beginConfiguration()
        
        // Add video input.
        do {
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                print("Default video device is unavailable.")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            
            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
                DispatchQueue.main.async {
                self.cameraPreviewView.videoPreviewLayer.connection?.videoOrientation = .landscapeRight
                }
            } else {
                print("Couldn't add video device input to the session.")
                setupResult = .configurationFailed
                session.commitConfiguration()
                return
            }
        } catch {
            print("Couldn't create video device input: \(error)")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        
        session.commitConfiguration()
    }
    
    private func initBLEControl() {
        guard let peripheral = self.selectedPeripheral else {
            return
        }
        let config = BLEDeviceConfig(maxAnalogOut: 8, maxLCDLines: 2)
        self.control = BLEControl(config: config, peripheral : peripheral, delegate: self)
        self.control?.initDevice()
        self.servoEnable(enable: true)
        self.bleReady = true
    }
    
    private func servoEnable(enable: Bool) {
        self.control?.analogOutEnable(index: 0, enable: enable)
        self.control?.analogOutEnable(index: 6, enable: enable)
    }
    
    // MARK: - BLE Serial Connection Delegates
    func didDiscover(peripheral: CBPeripheral, rssi: NSNumber) {
        DispatchQueue.main.async {
            for existing in self.peripherals {
                // don't add the same peripheral twice
                if peripheral.identifier == existing.0.identifier {
                    return
                }
            }
            self.peripherals.append((peripheral, rssi))
            // Just connect automatically to first peripheral ignoring all others
            // (Assumes just one BLE device exists)
            self.selectedPeripheral = self.peripherals[0].0
            self.serial?.stopScan()
            if let peripheral = self.selectedPeripheral,
                let serial =  self.serial {
                if !serial.connectToPeripheral(peripheral) {
                    print("Please ensure bluetooth is on in settings")
                }
            }
        }
    }
    
    func didConnect() {
        DispatchQueue.main.async {
            print("BLE Device connected")
            DispatchQueue.main.async {
                self.electronicsImageView.tintColor = UIColor.green
            }
            self.bleConnected = true
            self.initBLEControl()
        }
    }
    
    func didFailToConnect(peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            print("Failed to connect to BLE peripheral")
            DispatchQueue.main.async {
                self.electronicsImageView.tintColor = UIColor.red
            }
            self.bleConnected = false
            self.tryReconnect()
        }
    }
    
    func didDisconnect(peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            print("BLE peripheral disconnected")
            DispatchQueue.main.async {
                self.electronicsImageView.tintColor = UIColor.red
            }
            self.bleConnected = false
            self.tryReconnect()
        }
    }
    
    func didUpdateState(state: CBManagerState) {
        if state == .poweredOn {
            print("Bluetooth on")
            DispatchQueue.main.async {
                self.bluetoothImageView.tintColor = UIColor.green
            }
            // Start scanning for BLE peripheral
            self.serial?.startScan()
        }
        else {
            print("Bluetooth off")
            DispatchQueue.main.async {
                self.bluetoothImageView.tintColor = UIColor.red
            }
        }
    }
    
    func tryReconnect() {
        self.serial?.stopScan()
        self.peripherals.removeAll()
        self.serial?.startScan()
    }
    
    // MARK: - BLEControl Delegate
    
    func deviceError(message: String) {
        print("Error from peripheral: \(message)")
    }
    
    // MARK: - Control messages
    
    func updateSteering(_ x : Float) {
        if x == self.prevSteering {
            return
        }
        self.prevSteering = x
        if self.bleConnected && self.bleReady {
            self.control?.servo[0] = 0.5*(x+1.0) // convert range -1..1 to 0..1
        }
    }
    
    func updateMotorSpeed(_ y : Float) {
        if y == self.prevMotorSpeed {
            return
        }
        self.prevMotorSpeed = y
        if self.bleConnected && self.bleReady {
            self.control?.pwm[6] = y
        }
    }
    
    // MARK: - MFi Game Controller
    
    func initGameController() {
        let controllers = GCController.controllers()
        if controllers.count > 0 {
            let extendedControllers = controllers.filter { ($0 as GCController).extendedGamepad != nil }
            if extendedControllers.count > 0 {
                self.gameController = extendedControllers[0]
                self.handleGameControllerInput()
            }
        }
    }
    
    @objc func gameControllerDidConnect(_ notification : Notification) {
        self.gameController = notification.object as? GCController
        print("MFi controller connected")
        DispatchQueue.main.async {
            self.joystickImageView.tintColor = UIColor.green
        }
        self.handleGameControllerInput()
    }
    
    @objc func gameControllerDidDisconnect(_ notification : Notification) {
        self.gameController = nil
        DispatchQueue.main.async {
            self.joystickImageView.tintColor = UIColor.red
        }
        print("MFi controller disconnected")
    }
    
    func handleGameControllerInput() {
        guard let profile = self.gameController?.extendedGamepad else {
            return
        }
        profile.valueChangedHandler = ({[unowned self] (gamepad: GCExtendedGamepad, element: GCControllerElement)  in
            switch(element) {
            case gamepad.leftTrigger:
                if gamepad.leftTrigger.isPressed {
                    print("left trigger pressed")
                }
                break
            case gamepad.rightTrigger:
                if gamepad.rightTrigger.isPressed  {
                    print("right trigger pressed")
                }
                break
            case gamepad.leftShoulder:
                if gamepad.leftShoulder.isPressed {
                    print("left shoulder pressed")
                }
                break
            case gamepad.rightShoulder:
                if gamepad.rightShoulder.isPressed {
                    print("right shoulder pressed")
                }
                break
            case gamepad.dpad:
                if gamepad.dpad.left.isPressed {
                    print("dpad left")
                }
                else if gamepad.dpad.right.isPressed {
                    print("dpad right")
                }
                if gamepad.dpad.up.isPressed {
                    print("dpad up")
                }
                else if gamepad.dpad.down.isPressed {
                    print("dpad down")
                }
                break
            case gamepad.leftThumbstick:
                let y = gamepad.leftThumbstick.yAxis.value
                self.updateMotorSpeed(y)
                if gamepad.leftThumbstick.left.isPressed {
                    print("left thumbstrick left")
                }
                else if gamepad.leftThumbstick.right.isPressed {
                    print("left thumbstrick right")
                }
                if gamepad.leftThumbstick.up.isPressed {
                    print("left thumbstrick up")
                }
                else if gamepad.leftThumbstick.down.isPressed {
                    print("left thumbstrick down")
                }
                break
            case gamepad.rightThumbstick:
                let x = gamepad.rightThumbstick.xAxis.value
                self.updateSteering(x)
                if gamepad.rightThumbstick.left.isPressed {
                    print("right thumbstrick left")
                }
                else if gamepad.rightThumbstick.right.isPressed {
                    print("right thumbstrick right")
                }
                if gamepad.rightThumbstick.up.isPressed {
                    print("right thumbstrick up")
                }
                else if gamepad.rightThumbstick.down.isPressed {
                    print("right thumbstrick down")
                }
                break
            case gamepad.buttonA:
                if gamepad.buttonA.isPressed {
                    print("button A pressed")
                }
                break
            case gamepad.buttonB:
                if gamepad.buttonB.isPressed {
                    print("button B pressed")
                }
                break
            case gamepad.buttonX:
                if gamepad.buttonX.isPressed {
                    print("button X pressed")
                }
                break
            case gamepad.buttonY:
                if gamepad.buttonY.isPressed {
                    print("button Y pressed")
                }
                break
            default:
                break
                
            }
        }) as GCExtendedGamepadValueChangedHandler
        
        profile.controller?.controllerPausedHandler = ({ (controller : GCController) -> Void in
            print("pause button pressed")
        })
    }
    
    // MARK: - Camera record functionality
    
    func addMovieFileOutput() {
        self.sessionQueue.async {
            let movieFileOutput = AVCaptureMovieFileOutput()
            
            if self.session.canAddOutput(movieFileOutput) {
                self.session.beginConfiguration()
                self.session.addOutput(movieFileOutput)
                self.session.sessionPreset = .high
                if let connection = movieFileOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                }
                self.session.commitConfiguration()
                
                self.movieFileOutput = movieFileOutput
            }
        }
    }
    
    // MARK: - AVCaptureFileOutputRecordingDelegate
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        // Note: Since we use a unique file path for each recording, a new recording won't overwrite a recording mid-save.
        func cleanup() {
            let path = outputFileURL.path
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    print("Could not remove file at url: \(outputFileURL)")
                }
            }
            
            if let currentBackgroundRecordingID = backgroundRecordingID {
                backgroundRecordingID = UIBackgroundTaskIdentifier.invalid
                
                if currentBackgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
                    UIApplication.shared.endBackgroundTask(currentBackgroundRecordingID)
                }
            }
        }
        
        var success = true
        
        if error != nil {
            print("Movie file finishing error: \(String(describing: error))")
            success = (((error! as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as AnyObject).boolValue)!
        }
        
        if success {
            // Check authorization status.
            PHPhotoLibrary.requestAuthorization { status in
                if status == .authorized {
                    // Save the movie file to the photo library and cleanup.
                    PHPhotoLibrary.shared().performChanges({
                        let options = PHAssetResourceCreationOptions()
                        options.shouldMoveFile = true
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        creationRequest.addResource(with: .video, fileURL: outputFileURL, options: options)
                    }, completionHandler: { success, error in
                        if !success {
                            print("Car Controller couldn't save the movie to your photo library: \(String(describing: error))")
                        }
                        cleanup()
                    }
                    )
                } else {
                    cleanup()
                }
            }
        } else {
            cleanup()
        }
        DispatchQueue.main.async {
            self.recordToggleButton.isEnabled = true
        }
    }
    
    // MARK: - Camera IB Actions
    
    @IBAction func startCameraPreview(_ sender: Any) {
        self.cameraPreviewView.isHidden = false
        self.sessionQueue.async {
            switch self.setupResult {
            case .success:
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
                self.addMovieFileOutput()
            case .notAuthorized:
                DispatchQueue.main.async {
                    let changePrivacySetting = "Car Controller doesn't have permission to use the camera, please change privacy settings"
                    let message = NSLocalizedString(changePrivacySetting, comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "Car Controller", message: message, preferredStyle: .alert)
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                                                            style: .`default`,
                                                            handler: { _ in
                                                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                                                          options: [:],
                                                                                          completionHandler: nil)
                    }))
                    
                    self.present(alertController, animated: true, completion: nil)
                }
                
            case .configurationFailed:
                DispatchQueue.main.async {
                    let alertMsg = "Alert message when something goes wrong during capture session configuration"
                    let message = NSLocalizedString("Unable to capture media", comment: alertMsg)
                    let alertController = UIAlertController(title: "Car Controller", message: message, preferredStyle: .alert)
                    
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))
                    
                    self.present(alertController, animated: true, completion: nil)
                }
            }
        }
    }
    
    @IBAction func stopCameraPreview(_ sender: Any) {
        self.cameraPreviewView.isHidden = true
        self.sessionQueue.async {
            switch self.setupResult {
            case .success:
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
            default:
                break
            }
        }
    }
    

    @IBAction func recordToggle(_ sender: UIButton) {
        guard let movieFileOutput = self.movieFileOutput else {
            return
        }
        if !movieFileOutput.isRecording {
            DispatchQueue.main.async {
                sender.imageView?.image = UIImage(named: "Stop")
                self.stopPreviewButton.isEnabled = false
            }

            let videoPreviewLayerOrientation = self.cameraPreviewView.videoPreviewLayer.connection?.videoOrientation
            
            sessionQueue.async {
                if UIDevice.current.isMultitaskingSupported {
                    self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                }
                
                // Update the orientation on the movie file output video connection before recording.
                let movieFileOutputConnection = movieFileOutput.connection(with: .video)
                movieFileOutputConnection?.videoOrientation = videoPreviewLayerOrientation!
                
                let availableVideoCodecTypes = movieFileOutput.availableVideoCodecTypes
                
                if availableVideoCodecTypes.contains(.hevc) {
                    movieFileOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: movieFileOutputConnection!)
                }
                
                // Start recording video to a temporary file.
                let outputFileName = NSUUID().uuidString
                let outputFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent((outputFileName as NSString).appendingPathExtension("mov")!)
                movieFileOutput.startRecording(to: URL(fileURLWithPath: outputFilePath), recordingDelegate: self)
            }
        }
        else {
            DispatchQueue.main.async {
                movieFileOutput.stopRecording()
                sender.imageView?.image = UIImage(named: "Record")
                // Disable record button until movie file transfer complete
                sender.isEnabled = false
                self.stopPreviewButton.isEnabled = true
            }
        }
    }
}



