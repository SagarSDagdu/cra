import Foundation
import ObjectiveC

/// Chromium's Bluetooth adapter, created once a page makes a WebAuthn request (passkeys on a
/// phone go over Bluetooth), polls the paired devices every 500 ms on the main thread, which
/// is also where Cra draws. Each `-[IOBluetoothDevice isPaired]` there is a synchronous XPC
/// round trip that fetches the whole paired list: ~23 ms of every second went to it, a frame
/// or two dropped twice a second while scrolling. Pairings change rarely; both answers are
/// cached for a few seconds.
enum ChromiumBluetoothCache {
    private static let lifetime: TimeInterval = 10
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pairedDevices: (value: AnyObject?, at: Date)?
    nonisolated(unsafe) private static var isPaired: [String: (value: Bool, at: Date)] = [:]

    private typealias ObjectIMP = @convention(c) (AnyObject, Selector) -> AnyObject?
    private typealias BoolIMP = @convention(c) (AnyObject, Selector) -> Bool

    /// After Chromium is loaded (it links IOBluetooth).
    static func install() {
        guard let cls = NSClassFromString("IOBluetoothDevice") else { return }
        if let method = class_getClassMethod(cls, NSSelectorFromString("pairedDevices")) {
            let sel = method_getName(method)
            let original = unsafeBitCast(method_getImplementation(method), to: ObjectIMP.self)
            let block: @convention(block) (AnyObject) -> AnyObject? = { obj in
                if let hit = lock.withLock({ pairedDevices }), Date().timeIntervalSince(hit.at) < lifetime { return hit.value }
                let value = original(obj, sel)
                lock.withLock { pairedDevices = (value, Date()) }
                return value
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
        if let method = class_getInstanceMethod(cls, NSSelectorFromString("isPaired")) {
            let sel = method_getName(method)
            let original = unsafeBitCast(method_getImplementation(method), to: BoolIMP.self)
            let addressSel = NSSelectorFromString("addressString")
            let block: @convention(block) (AnyObject) -> Bool = { obj in
                guard obj.responds(to: addressSel),
                      let address = obj.perform(addressSel)?.takeUnretainedValue() as? String else { return original(obj, sel) }
                if let hit = lock.withLock({ isPaired[address] }), Date().timeIntervalSince(hit.at) < lifetime { return hit.value }
                let value = original(obj, sel)
                lock.withLock { isPaired[address] = (value, Date()) }
                return value
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}
