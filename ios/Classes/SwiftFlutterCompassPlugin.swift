import Flutter
import UIKit
import CoreLocation
import CoreMotion
import simd

public class SwiftFlutterCompassPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CLLocationManagerDelegate {

    private var eventSink: FlutterEventSink?;
    private var location: CLLocationManager = CLLocationManager();
    private var motion: CMMotionManager = CMMotionManager();

    // Below this many degrees of change Core Location does not deliver a
    // heading update. The upstream value of 0.1 let a phone lying still send
    // several events a second of magnetometer jitter across the channel, each
    // one a Dart-side state change. One degree is under a pixel at the rim of
    // the app's 40 pt compass face, and the app's own stationary deadband
    // (two degrees) sits above it, so nothing the UI could show is lost.
    private static let headingFilterDegrees: CLLocationDegrees = 1.0;

    // Device motion is only read when a heading update arrives, to compute
    // the heading out of the back of the device for the camera mode. 15 Hz
    // keeps that attitude at most ~67 ms stale, which a turning phone cannot
    // see, at half the sensor-fusion work of the upstream 30 Hz.
    private static let deviceMotionInterval: TimeInterval = 1.0 / 15.0;

    init(channel: FlutterEventChannel) {
        super.init()
        location.delegate = self
        location.headingFilter = SwiftFlutterCompassPlugin.headingFilterDegrees;
        channel.setStreamHandler(self);

        motion.deviceMotionUpdateInterval = SwiftFlutterCompassPlugin.deviceMotionInterval;
        // Nothing is started here. Upstream started device motion in this
        // initialiser, which runs at plugin registration during app launch,
        // and never stopped it, so CoreMotion ran for the whole process
        // lifetime, in the background included, whether or not anything
        // listened. Both feeds now start in onListen and stop in onCancel.
    }


  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterEventChannel.init(name: "hemanthraj/flutter_compass", binaryMessenger: registrar.messenger())
    _ = SwiftFlutterCompassPlugin(channel: channel);
  }

    public func onListen(withArguments arguments: Any?,
                         eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink;
        if (motion.isDeviceMotionAvailable && !motion.isDeviceMotionActive) {
            motion.startDeviceMotionUpdates(using: CMAttitudeReferenceFrame.xMagneticNorthZVertical);
        }
        location.startUpdatingHeading();
        return nil;
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil;
        location.stopUpdatingHeading();
        motion.stopDeviceMotionUpdates();
        return nil;
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if (newHeading.headingAccuracy>0){
            var trueHeading = newHeading.trueHeading;
            var headingForCameraMode = trueHeading;
            // If device orientation data is available, use it to calculate the heading out the the
            // back of the device (rather than out the top of the device).
            if let data = self.motion.deviceMotion?.attitude {
                // Re-map the device orientation matrix such that the Z axis (out the back of the device)
                // always reads -90deg off magnetic north. All rotation matrices use + rotation to mean
                // counter-clockwise.
                let r1 = double3x3(rows: [
                    simd_double3(0, 0, 1),
                    simd_double3(0, 1, 0),
                    simd_double3(-1, 0, 0)
                ]); // -90 around the Y axis
                let r2 = double3x3(rows: [
                    simd_double3(0, -1, 0),
                    simd_double3(1, 0, 0),
                    simd_double3(0, 0, 1)
                ]); // -90 around the Z axis
                let R = double3x3(rows: [
                    simd_double3(data.rotationMatrix.m11, data.rotationMatrix.m12, data.rotationMatrix.m13),
                    simd_double3(data.rotationMatrix.m21, data.rotationMatrix.m22, data.rotationMatrix.m23),
                    simd_double3(data.rotationMatrix.m31, data.rotationMatrix.m32, data.rotationMatrix.m33)
                ]);
                let T = r2 * r1 * R;
                // Calculate yaw from R and add 90deg.
                let yaw = atan2(T[0, 1], T[1, 1]) + Double.pi / 2;
                headingForCameraMode = (yaw + Double.pi * 2).truncatingRemainder(dividingBy: Double.pi * 2) * 180.0 / Double.pi;
            }
            var headingForUI = trueHeading;
            switch UIApplication.shared.statusBarOrientation {
                case .portrait:
                    headingForUI = trueHeading
                case .portraitUpsideDown:
                    headingForUI = trueHeading + 180
                case .landscapeRight:
                    headingForUI = trueHeading + 90
                case .landscapeLeft:
                    headingForUI = trueHeading - 90
                default:
                    headingForUI = trueHeading
            }
            eventSink?([headingForUI, headingForCameraMode, newHeading.headingAccuracy]);
        }
    }
}
