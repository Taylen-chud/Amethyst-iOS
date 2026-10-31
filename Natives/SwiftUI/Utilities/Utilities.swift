import Foundation
import UIKit


/// Single-argument convenience over the Obj-C `localize(key, comment)` in utils.h.
func localize(_ key: String) -> String {
    return localize(key, nil) ?? key
}

// MARK: - Device / environment

/// The Obj-C side uses `#define realUIIdiom UIDevice.currentDevice.userInterfaceIdiom`
/// (UIKit+hook.h), which Swift cannot see, so mirror it here.
var realUIIdiom: UIUserInterfaceIdiom {
    return UIDevice.current.userInterfaceIdiom
}

var NSRunningOnMacCatalyst: Bool {
    return ProcessInfo.processInfo.isMacCatalystApp
}

/// Safe wrapper around getenv(). `"\(getenv("X")!)"` would print the pointer, not the string.
func envString(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    return String(cString: value)
}

/// Value of GAME_DIR, or an empty string when it is not set yet.
var gameDir: String {
    return envString("GAME_DIR") ?? ""
}

/// `_UISolariumEnabled` is a weak-imported private UIKit symbol (iOS 26 Liquid Glass).
/// It does not exist on older systems, so look it up at runtime instead of linking to it.
private let solariumEnabled: Bool = {
    // RTLD_DEFAULT is ((void *)-2)
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_UISolariumEnabled") else {
        return false
    }
    typealias SolariumFunc = @convention(c) () -> Bool
    return unsafeBitCast(symbol, to: SolariumFunc.self)()
}()

var hasLiquidGlass: Bool {
    return solariumEnabled
}

/// Obj-C `NSDebugLog(...)` is a macro, so Swift gets a function instead.
func NSDebugLog(_ message: @autoclosure () -> String) {
    if debugLogEnabled {
        NSLog("%@", message())
    }
}

/// `+[HostManager GetModelName]`, called by selector so the Swift import name does not matter.
func hostModelName() -> String {
    guard let cls = NSClassFromString("HostManager") else { return "unknown" }
    let result = (cls as AnyObject).perform(NSSelectorFromString("GetModelName"))
    return result?.takeUnretainedValue() as? String ?? "unknown"
}

// MARK: - UIImage / image loading

extension UIImage {
    func resized(to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in self.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

private let remoteImageCache = NSCache<NSURL, UIImage>()

/// Tiny replacement for the AFNetworking `setImageWithURL:placeholderImage:` helpers.
private func loadRemoteImage(_ url: URL?, placeholder: UIImage?, apply: @escaping (UIImage?) -> Void) {
    guard let url = url else {
        apply(placeholder)
        return
    }
    if let cached = remoteImageCache.object(forKey: url as NSURL) {
        apply(cached)
        return
    }
    apply(placeholder)
    URLSession.shared.dataTask(with: url) { data, _, _ in
        guard let data = data, let image = UIImage(data: data) else { return }
        remoteImageCache.setObject(image, forKey: url as NSURL)
        DispatchQueue.main.async { apply(image) }
    }.resume()
}

extension UIButton {
    func setRemoteImage(_ url: URL?, for state: UIControl.State, placeholder: UIImage?) {
        loadRemoteImage(url, placeholder: placeholder) { [weak self] image in
            self?.setImage(image, for: state)
            self?.sizeToFit()
        }
    }
}

extension UIImageView {
    func setRemoteImage(_ url: URL?, placeholder: UIImage?) {
        loadRemoteImage(url, placeholder: placeholder) { [weak self] image in
            self?.image = image
        }
    }
}

// MARK: - Sidebar access

extension UIViewController {
    /// Obj-C `sidebarViewController` macro: the launcher menu in the first column of the split view.
    var sidebarViewController: LauncherMenuViewController? {
        let nav = splitViewController?.viewControllers.first as? UINavigationController
        return nav?.viewControllers.first as? LauncherMenuViewController
    }
}

// MARK: - Calling Obj-C methods by selector

// Used for core methods whose Swift import name is easy to get wrong (`fooWithBar:` can come in as `foo(bar:)` or
// `foo(withBar:)`). The selector is the same one the Obj-C code used, so there is nothing to guess.

/// `[target selector]`, result is an object (or nil)
@discardableResult
func objcSend(_ target: AnyObject, _ selector: String) -> AnyObject? {
    let sel = NSSelectorFromString(selector)
    guard target.responds(to: sel), let imp = target.method(for: sel) else {
        NSLog("[objcSend] %@ does not respond to %@", String(describing: type(of: target)), selector)
        return nil
    }
    typealias Function = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    return unsafeBitCast(imp, to: Function.self)(target, sel)?.takeUnretainedValue()
}

/// `[target selector:a]`
@discardableResult
func objcSend(_ target: AnyObject, _ selector: String, _ a: AnyObject?) -> AnyObject? {
    let sel = NSSelectorFromString(selector)
    guard target.responds(to: sel), let imp = target.method(for: sel) else {
        NSLog("[objcSend] %@ does not respond to %@", String(describing: type(of: target)), selector)
        return nil
    }
    typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
    return unsafeBitCast(imp, to: Function.self)(target, sel, a)?.takeUnretainedValue()
}

/// `[target selector:a b:b]`
@discardableResult
func objcSend(_ target: AnyObject, _ selector: String, _ a: AnyObject?, _ b: AnyObject?) -> AnyObject? {
    let sel = NSSelectorFromString(selector)
    guard target.responds(to: sel), let imp = target.method(for: sel) else {
        NSLog("[objcSend] %@ does not respond to %@", String(describing: type(of: target)), selector)
        return nil
    }
    typealias Function = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
    return unsafeBitCast(imp, to: Function.self)(target, sel, a, b)?.takeUnretainedValue()
}

/// `[target selector:a b:index]` where the second argument is an NSUInteger and nothing is returned
func objcSendObjectAndIndex(_ target: AnyObject, _ selector: String, _ a: AnyObject?, _ index: Int) {
    let sel = NSSelectorFromString(selector)
    guard target.responds(to: sel), let imp = target.method(for: sel) else {
        NSLog("[objcSend] %@ does not respond to %@", String(describing: type(of: target)), selector)
        return
    }
    typealias Function = @convention(c) (AnyObject, Selector, AnyObject?, Int) -> Void
    unsafeBitCast(imp, to: Function.self)(target, sel, a, index)
}

// MARK: - HTTP

/// Replacement for `[[AFHTTPSessionManager manager] GET:url parameters:nil ...]` with the default JSON response
/// serializer: 2xx only, JSON body. The completion runs on the main queue like AFNetworking's.
func httpGetJSON(_ urlString: String, completion: @escaping (_ response: Any?, _ error: Error?) -> Void) {
    guard let url = URL(string: urlString) else {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])
        DispatchQueue.main.async { completion(nil, error) }
        return
    }
    var request = URLRequest(url: url)
    request.setValue("application/json, text/json, text/javascript", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { data, response, error in
        var result: Any? = nil
        var failure: Error? = error
        if failure == nil, let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let text = String(format: "Request failed: %@ (%ld)", HTTPURLResponse.localizedString(forStatusCode: http.statusCode), http.statusCode)
            failure = NSError(domain: "com.alamofire.error.serialization.response", code: NSURLErrorBadServerResponse, userInfo: [
                NSLocalizedDescriptionKey: text,
                NSURLErrorFailingURLErrorKey: url
            ])
        }
        if failure == nil {
            do {
                result = try JSONSerialization.jsonObject(with: data ?? Data(), options: [.fragmentsAllowed])
            } catch {
                failure = error
            }
        }
        DispatchQueue.main.async { completion(result, failure) }
    }.resume()
}

// MARK: - Icon resizing

extension UIImage {
    /// `-[UIImage _imageWithSize:]` (private, declared in UIKit+hook.h) called through its IMP, so the Swift import
    /// name does not matter. Falls back to a plain redraw.
    func iconResized(to size: CGSize) -> UIImage {
        let selector = NSSelectorFromString("_imageWithSize:")
        if responds(to: selector), let imp = method(for: selector) {
            typealias ResizeFunc = @convention(c) (AnyObject, Selector, CGSize) -> Unmanaged<UIImage>?
            if let result = unsafeBitCast(imp, to: ResizeFunc.self)(self, selector, size) {
                return result.takeUnretainedValue()
            }
        }
        return resized(to: size)
    }
}
