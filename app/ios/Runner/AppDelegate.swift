// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreLocation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var locationHandler: LocationChannelHandler?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    locationHandler = LocationChannelHandler(messenger: messenger)
  }
}

final class LocationChannelHandler: NSObject, CLLocationManagerDelegate, FlutterStreamHandler {
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private let locationManager = CLLocationManager()
  private var eventSink: FlutterEventSink?
  private var pendingPermissionResult: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "dev.neurieder.against_yesterday/location",
      binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(
      name: "dev.neurieder.against_yesterday/location_updates",
      binaryMessenger: messenger)
    super.init()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
    methodChannel.setMethodCallHandler(handle)
    eventChannel.setStreamHandler(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isLocationServiceEnabled":
      result(CLLocationManager.locationServicesEnabled())
    case "checkPermission":
      result(permissionString(locationManager.authorizationStatus))
    case "requestPermission":
      let status = locationManager.authorizationStatus
      if status == .authorizedWhenInUse || status == .authorizedAlways {
        result("granted")
        return
      }
      if status == .denied || status == .restricted {
        result("deniedForever")
        return
      }
      pendingPermissionResult = result
      locationManager.requestWhenInUseAuthorization()
    case "openAppSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    case "openLocationSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func permissionString(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .authorizedWhenInUse, .authorizedAlways:
      return "granted"
    case .notDetermined:
      return "denied"
    case .denied, .restricted:
      return "deniedForever"
    @unknown default:
      return "denied"
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    locationManager.startUpdatingLocation()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    locationManager.stopUpdatingLocation()
    eventSink = nil
    return nil
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if let result = pendingPermissionResult {
      pendingPermissionResult = nil
      result(permissionString(manager.authorizationStatus))
    }
  }

  func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
    if #available(iOS 14.0, *) { return }
    if let result = pendingPermissionResult {
      pendingPermissionResult = nil
      result(permissionString(status))
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let loc = locations.last, let sink = eventSink else { return }
    var payload: [String: Any] = [
      "latitude": loc.coordinate.latitude,
      "longitude": loc.coordinate.longitude,
      "timestamp": Int(loc.timestamp.timeIntervalSince1970 * 1000),
    ]
    if loc.horizontalAccuracy >= 0 {
      payload["accuracy"] = loc.horizontalAccuracy
    }
    if loc.verticalAccuracy >= 0 {
      payload["altitude"] = loc.altitude
    }
    if loc.speed >= 0 {
      payload["speed"] = loc.speed
    }
    if loc.course >= 0 {
      payload["bearing"] = loc.course
    }
    sink(payload)
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Ignore; the stream stays open.
  }
}