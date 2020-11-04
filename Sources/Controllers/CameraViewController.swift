import UIKit
import AVFoundation

/// Delegate to handle camera setup and video capturing.
protocol CameraViewControllerDelegate: class {
  func cameraViewControllerDidSetupCaptureSession(_ controller: CameraViewController)
  func cameraViewControllerDidFailToSetupCaptureSession(_ controller: CameraViewController)
  func cameraViewController(_ controller: CameraViewController, didReceiveError error: Error)
  func cameraViewControllerDidTapSettingsButton(_ controller: CameraViewController)
  func cameraViewController(
    _ controller: CameraViewController,
    didOutput metadataObjects: [AVMetadataObject]
  )
}

/// View controller responsible for camera controls and video capturing.
public final class CameraViewController: UIViewController {
  weak var delegate: CameraViewControllerDelegate?

  /// Focus view type.
  public var barCodeFocusViewType: FocusViewType = .oneDimension
  public var showsCameraButton: Bool = false {
    didSet {
      cameraButton.isHidden = showsCameraButton
    }
  }
  /// `AVCaptureMetadataOutput` metadata object types.
  var metadata = [AVMetadataObject.ObjectType]()

  // MARK: - UI proterties

  /// Animated focus view.
  public private(set) lazy var focusView: UIView = self.makeFocusView()
  /// Button to change torch mode.
  public private(set) lazy var flashButton: UIButton = UIButton()
  /// Button that opens settings to allow camera usage.
  public private(set) lazy var settingsButton: UIButton = self.makeSettingsButton()
  // Button to switch between front and back camera.
  public private(set) lazy var cameraButton: UIButton = self.makeCameraButton()

  // Constraints for the focus view when it gets smaller in size.
  private var regularFocusViewConstraints = [NSLayoutConstraint]()
  // Constraints for the focus view when it gets bigger in size.
  private var animatedFocusViewConstraints = [NSLayoutConstraint]()

  // MARK: - Video

  /// Video preview layer.
  private var videoPreviewLayer: AVCaptureVideoPreviewLayer?
  /// Video capture device. This may be nil when running in Simulator.
  private var captureDevice: AVCaptureDevice?
  /// Capture session.
  private lazy var captureSession: AVCaptureSession = AVCaptureSession()
  // Service used to check authorization status of the capture device
  private let permissionService = VideoPermissionService()

  /// The current torch mode on the capture device.
  private var torchMode: TorchMode = .off {
    didSet {
      guard let captureDevice = captureDevice, captureDevice.hasFlash else { return }
      guard captureDevice.isTorchModeSupported(torchMode.captureTorchMode) else { return }

      do {
        try captureDevice.lockForConfiguration()
        captureDevice.torchMode = torchMode.captureTorchMode
//        if torchMode.captureTorchMode == .on {
//            flashButton.isSelected = true
//        }else{
//            flashButton.isSelected = false
//        }
        captureDevice.unlockForConfiguration()
      } catch {}
        
        print(flashButton.isSelected)
        
    }
  }

  private var frontCameraDevice: AVCaptureDevice? {
    return AVCaptureDevice.devices(for: .video).first(where: { $0.position == .front })
  }

  private var backCameraDevice: AVCaptureDevice? {
    return AVCaptureDevice.default(for: .video)
  }
    var startLocation = CGPoint()
  // MARK: - Initialization

  deinit {
    stopCapturing()
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - View lifecycle

  public override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    videoPreviewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
    videoPreviewLayer?.videoGravity = .resizeAspectFill

    guard let videoPreviewLayer = videoPreviewLayer else {
      return
    }
    focusView.isHidden = true
    flashButton.backgroundColor = UIColor.clear
    flashButton.layer.cornerRadius = 30
    flashButton.clipsToBounds = true
    flashButton.setImage(UIImage(named: "diantong"), for: .normal)
    
    view.layer.addSublayer(videoPreviewLayer)
    view.addSubviews(settingsButton, flashButton, focusView, cameraButton)
  
    flashButton.setImage(UIImage(named: "diantongselect"), for: .selected)
    torchMode = .off
    focusView.isHidden = true
    setupCamera()
    setupConstraints()
    setupActions()
    
    
    let panRecognizer = UIPanGestureRecognizer(target: self, action:  #selector(panedView))
       self.view.addGestureRecognizer(panRecognizer)
  }
    @objc func panedView(sender:UIPanGestureRecognizer){
           //var startLocation = CGPoint()
           //UIGestureRecognizerState has been renamed to UIGestureRecognizer.State in Swift 4
           if (sender.state == UIGestureRecognizer.State.began) {
               startLocation = sender.location(in: self.view)
           }else if sender.state == UIGestureRecognizer.State.changed
           {
                
                let stopLocation = sender.location(in: self.view)
                let dx = stopLocation.x - startLocation.x;
                let dy = stopLocation.y - startLocation.y;
                let distance = sqrt(dx*dx + dy*dy );
                
                
            
               // var sc = Int(dy/100)
            
                if let captureDevice =  self.captureDevice {
                    let d = distance/300
                    var zoom = CGFloat(0)
                    if dy < 0 {
                        zoom = captureDevice.videoZoomFactor - d
                        if zoom < 1 {
                            zoom = 1
                        }
                    }else
                    {
                        zoom = captureDevice.videoZoomFactor + d
                        if zoom > captureDevice.activeFormat.videoMaxZoomFactor {
                            zoom = captureDevice.activeFormat.videoMaxZoomFactor
                        }
                    }
                    do {
                        
                        try captureDevice.lockForConfiguration()
                        
                        
                       
                        captureDevice.videoZoomFactor = zoom
                        
                       
                        captureDevice.unlockForConfiguration()
                        
                      } catch {
                         print("Error setting configuration: \(error)")
                      }
                }
            
            
                //let distance = sqrt(dx*dx + dy*dy );
               // NSLog("changedDistance dy: %f", dy);
           }

           
   }
    
    
    
    
    
  public override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    setupVideoPreviewLayerOrientation()
    animateFocusView()
  }

  public override func viewWillTransition(to size: CGSize,
                                          with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate(
      alongsideTransition: { [weak self] _ in
        self?.setupVideoPreviewLayerOrientation()
      },
      completion: ({ [weak self] _ in
        self?.animateFocusView()
      }))
  }

  // MARK: - Video capturing

  func startCapturing() {
    guard !isSimulatorRunning else {
      return
    }

    torchMode = .off
    captureSession.startRunning()
    focusView.isHidden = false
    flashButton.isHidden = captureDevice?.position == .front
    cameraButton.isHidden = !showsCameraButton
  }

  func stopCapturing() {
    guard !isSimulatorRunning else {
      return
    }

    torchMode = .off
    captureSession.stopRunning()
    focusView.isHidden = true
    flashButton.isHidden = true
    cameraButton.isHidden = true
  }

  // MARK: - Actions

  private func setupActions() {
    flashButton.addTarget(
      self,
      action: #selector(handleFlashButtonTap),
      for: .touchUpInside
    )
    settingsButton.addTarget(
      self,
      action: #selector(handleSettingsButtonTap),
      for: .touchUpInside
    )
    cameraButton.addTarget(
      self,
      action: #selector(handleCameraButtonTap),
      for: .touchUpInside
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  /// `UIApplicationWillEnterForegroundNotification` action.
  @objc private func appWillEnterForeground() {
    torchMode = .off
    animateFocusView()
  }

  /// Opens setting to allow camera usage.
  @objc private func handleSettingsButtonTap() {
    delegate?.cameraViewControllerDidTapSettingsButton(self)
  }

  /// Swaps camera position.
  @objc private func handleCameraButtonTap() {
    swapCamera()
  }

  /// Sets the next torch mode.
  @objc private func handleFlashButtonTap() {
    flashButton.isSelected =  !flashButton.isSelected
    torchMode = torchMode.next
  }

  // MARK: - Camera setup

  /// Sets up camera and checks for camera permissions.
  private func setupCamera() {
    permissionService.checkPersmission { [weak self] error in
      guard let strongSelf = self else {
        return
      }

      DispatchQueue.main.async { [weak self] in
        self?.settingsButton.isHidden = error == nil
      }

      if error == nil {
        strongSelf.setupSessionInput(for: .back)
        strongSelf.setupSessionOutput()
        strongSelf.delegate?.cameraViewControllerDidSetupCaptureSession(strongSelf)
      } else {
        strongSelf.showAlert(title: "提示", message: "请检查相机是否打开", buttonTitles: ["取消","确定"], highlightedButtonIndex: 1) { (index) in
            
            if index == 1
            {
                DispatchQueue.main.async {
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.openURL(settingsURL)
                  }
                }
            }
        }
        strongSelf.delegate?.cameraViewControllerDidFailToSetupCaptureSession(strongSelf)
      }
    }
  }
    
    @discardableResult
    func showAlert(title: String?, message: String?, buttonTitles: [String]? = nil, highlightedButtonIndex: Int? = nil, completion: ((Int) -> Void)? = nil) -> UIAlertController {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        var allButtons = buttonTitles ?? [String]()
        if allButtons.count == 0 {
            allButtons.append("OK")
        }

        for index in 0..<allButtons.count {
            let buttonTitle = allButtons[index]
            let action = UIAlertAction(title: buttonTitle, style: .default, handler: { (_) in
                completion?(index)
            })
            alertController.addAction(action)
            // Check which button to highlight
            if let highlightedButtonIndex = highlightedButtonIndex, index == highlightedButtonIndex {
                if #available(iOS 9.0, *) {
                    alertController.preferredAction = action
                }
            }
        }
        present(alertController, animated: true, completion: nil)
        return alertController
    }

  /// Sets up capture input, output and session.
  private func setupSessionInput(for position: AVCaptureDevice.Position) {
    guard !isSimulatorRunning else {
      return
    }

    guard let device = position == .front ? frontCameraDevice : backCameraDevice else {
      return
    }

    do {
      let newInput = try AVCaptureDeviceInput(device: device)
      captureDevice = device
      // Swap capture device inputs
      captureSession.beginConfiguration()
      if let currentInput = captureSession.inputs.first as? AVCaptureDeviceInput {
        captureSession.removeInput(currentInput)
      }
      captureSession.addInput(newInput)
      captureSession.commitConfiguration()
      flashButton.isHidden = position == .front
    } catch {
      delegate?.cameraViewController(self, didReceiveError: error)
      return
    }
  }

  private func setupSessionOutput() {
    guard !isSimulatorRunning else {
      return
    }

    let output = AVCaptureMetadataOutput()
    captureSession.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
    output.metadataObjectTypes = metadata
    videoPreviewLayer?.session = captureSession

    view.setNeedsLayout()
  }

  /// Switch front/back camera.
  private func swapCamera() {
    guard let input = captureSession.inputs.first as? AVCaptureDeviceInput else {
      return
    }
    setupSessionInput(for: input.device.position == .back ? .front : .back)
  }

  // MARK: - Animations

  /// Performs focus view animation.
  private func animateFocusView() {
    // Restore to initial state
    focusView.layer.removeAllAnimations()
    animatedFocusViewConstraints.deactivate()
    regularFocusViewConstraints.activate()
    view.layoutIfNeeded()

    guard barCodeFocusViewType == .animated else {
      return
    }

    regularFocusViewConstraints.deactivate()
    animatedFocusViewConstraints.activate()

    UIView.animate(
      withDuration: 1.0,
      delay: 0,
      options: [.repeat, .autoreverse, .beginFromCurrentState],
      animations: ({ [weak self] in
        self?.view.layoutIfNeeded()
      }),
      completion: nil
    )
  }
}

// MARK: - Layout

private extension CameraViewController {
  func setupConstraints() {
    if #available(iOS 11.0, *) {
      NSLayoutConstraint.activate(
        flashButton.bottomAnchor.constraint(
          equalTo: view.safeAreaLayoutGuide.bottomAnchor,
          constant: -30
        ),
        flashButton.centerXAnchor.constraint(
          equalTo: view.safeAreaLayoutGuide.centerXAnchor,
          constant: 0
        ),
        cameraButton.bottomAnchor.constraint(
          equalTo: view.safeAreaLayoutGuide.bottomAnchor,
          constant: -30
        )
      )
    } else {
      NSLayoutConstraint.activate(
        flashButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 30),
        flashButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -13),
        cameraButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -30)
      )
    }

    let imageButtonSize: CGFloat = 60

    NSLayoutConstraint.activate(
      flashButton.widthAnchor.constraint(equalToConstant: imageButtonSize),
      flashButton.heightAnchor.constraint(equalToConstant: imageButtonSize),

      settingsButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      settingsButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      settingsButton.widthAnchor.constraint(equalToConstant: 150),
      settingsButton.heightAnchor.constraint(equalToConstant: 50),

      cameraButton.widthAnchor.constraint(equalToConstant: 48),
      cameraButton.heightAnchor.constraint(equalToConstant: 48),
      cameraButton.trailingAnchor.constraint(equalTo: flashButton.trailingAnchor)
    )

    setupFocusViewConstraints()
  }

  func setupFocusViewConstraints() {
    NSLayoutConstraint.activate(
      focusView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      focusView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
    )

    let focusViewSize = barCodeFocusViewType == .oneDimension
      ? CGSize(width: 280, height: 80)
      : CGSize(width: 218, height: 150)

    regularFocusViewConstraints = [
      focusView.widthAnchor.constraint(equalToConstant: focusViewSize.width),
      focusView.heightAnchor.constraint(equalToConstant: focusViewSize.height)
    ]

    animatedFocusViewConstraints = [
      focusView.widthAnchor.constraint(equalToConstant: 280),
      focusView.heightAnchor.constraint(equalToConstant: 80)
    ]

    NSLayoutConstraint.activate(regularFocusViewConstraints)
  }

  func setupVideoPreviewLayerOrientation() {
    guard let videoPreviewLayer = videoPreviewLayer else {
      return
    }

    videoPreviewLayer.frame = view.layer.bounds

    if let connection = videoPreviewLayer.connection, connection.isVideoOrientationSupported {
      switch UIApplication.shared.statusBarOrientation {
      case .portrait:
        connection.videoOrientation = .portrait
      case .landscapeRight:
        connection.videoOrientation = .landscapeRight
      case .landscapeLeft:
        connection.videoOrientation = .landscapeLeft
      case .portraitUpsideDown:
        connection.videoOrientation = .portraitUpsideDown
      default:
        connection.videoOrientation = .portrait
      }
    }
  }
}

// MARK: - Subviews factory

private extension CameraViewController {
  func makeFocusView() -> UIView {
    let view = UIView()
//    view.layer.borderColor = UIColor.white.cgColor
//    view.layer.borderWidth = 2
//    view.layer.cornerRadius = 5
//    view.layer.shadowColor = UIColor.white.cgColor
//    view.layer.shadowRadius = 10.0
//    view.layer.shadowOpacity = 0.9
//    view.layer.shadowOffset = CGSize.zero
//    view.layer.masksToBounds = false
    return view
  }

  func makeSettingsButton() -> UIButton {
    let button = UIButton(type: .system)
    let title = NSAttributedString(
      string: localizedString("BUTTON_SETTINGS"),
      attributes: [.font: UIFont.boldSystemFont(ofSize: 17), .foregroundColor: UIColor.white]
    )
    button.setAttributedTitle(title, for: UIControl.State())
    button.sizeToFit()
    return button
  }

  func makeCameraButton() -> UIButton {
    let button = UIButton(type: .custom)
    button.setImage(imageNamed("cameraRotate"), for: UIControl.State())
    button.isHidden = !showsCameraButton
    return button
  }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension CameraViewController: AVCaptureMetadataOutputObjectsDelegate {
  public func metadataOutput(_ output: AVCaptureMetadataOutput,
                             didOutput metadataObjects: [AVMetadataObject],
                             from connection: AVCaptureConnection) {
    delegate?.cameraViewController(self, didOutput: metadataObjects)
  }
}
