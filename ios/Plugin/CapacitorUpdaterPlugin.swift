import Foundation
import Capacitor
import Version

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(CapacitorUpdaterPlugin)
public class CapacitorUpdaterPlugin: CAPPlugin {
    private var implementation = CapacitorUpdater()
    static let autoUpdateUrlDefault = "https://xvwzpoazmxkqosrdewyv.functions.supabase.co/updates"
    static let statsUrlDefault = "https://xvwzpoazmxkqosrdewyv.functions.supabase.co/stats"
    static let DELAY_UPDATE = "delayUpdate"
    private var autoUpdateUrl = ""
    private var statsUrl = ""
    private var currentVersionNative: Version = "0.0.0"
    private var autoUpdate = false
    private var appReadyTimeout = 10000
    private var appReadyCheck: DispatchWorkItem?
    private var resetWhenUpdate = true
    private var autoDeleteFailed = false
    private var autoDeletePrevious = false
    
    override public func load() {
        do {
            currentVersionNative = try Version(Bundle.main.buildVersionNumber ?? "0.0.0")
        } catch {
            print("\(self.implementation.TAG) Cannot get version native \(currentVersionNative)")
        }
        autoDeleteFailed = getConfigValue("autoDeleteFailed") as? Bool ?? false
        autoDeletePrevious = getConfigValue("autoDeletePrevious") as? Bool ?? false
        autoUpdateUrl = getConfigValue("autoUpdateUrl") as? String ?? CapacitorUpdaterPlugin.autoUpdateUrlDefault
        autoUpdate = getConfigValue("autoUpdate") as? Bool ?? false
        appReadyTimeout = getConfigValue("appReadyTimeout") as? Int ?? 10000
        resetWhenUpdate = getConfigValue("resetWhenUpdate") as? Bool ?? true

        implementation.appId = Bundle.main.bundleIdentifier ?? ""
        implementation.notifyDownload = notifyDownload
        let config = (self.bridge?.viewController as? CAPBridgeViewController)?.instanceDescriptor().legacyConfig
        if (config?["appId"] != nil) {
            implementation.appId = config?["appId"] as! String
        }
        implementation.statsUrl = getConfigValue("statsUrl") as? String ?? CapacitorUpdaterPlugin.statsUrlDefault

        if (resetWhenUpdate) {
            self.cleanupObsoleteVersions()
        }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(appMovedToBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(appMovedToForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        self.appMovedToForeground()
    }

    private func cleanupObsoleteVersions() {
        var LatestVersionNative: Version = "0.0.0"
        do {
            LatestVersionNative = try Version(UserDefaults.standard.string(forKey: "LatestVersionNative") ?? "0.0.0")
        } catch {
            print("\(self.implementation.TAG) Cannot get version native \(currentVersionNative)")
        }
        if (LatestVersionNative != "0.0.0" && currentVersionNative.major > LatestVersionNative.major) {
            _ = self._reset(toAutoUpdate: false)
            UserDefaults.standard.set("", forKey: "LatestVersionAutoUpdate")
            UserDefaults.standard.set("", forKey: "LatestVersionNameAutoUpdate")
            let res = implementation.list()
            res.forEach { version in
                print("\(self.implementation.TAG) Deleting obsolete bundle: \(version)")
                _ = implementation.delete(id: version.getId())
            }
        }
        UserDefaults.standard.set( self.currentVersionNative.description, forKey: "LatestVersionNative")
        UserDefaults.standard.synchronize()
    }

    @objc func notifyDownload(id: String, percent: Int) {
        let bundle = self.implementation.getBundleInfo(id: id)
        self.notifyListeners("download", data: ["percent": percent, "bundle": bundle.toJSON()])
        if (percent == 100) {
            self.notifyListeners("downloadComplete", data: ["bundle": bundle.toJSON()])
        }
    }

    @objc func getId(_ call: CAPPluginCall) {
        call.resolve(["id": implementation.deviceID])
    }

    @objc func getPluginVersion(_ call: CAPPluginCall) {
        call.resolve(["version": implementation.pluginVersion])
    }
    
    @objc func download(_ call: CAPPluginCall) {
        guard let urlString = call.getString("url") else {
            print("\(self.implementation.TAG) Download called without url")
            call.reject("Download called without url")
            return
        }
        guard let version = call.getString("version") else {
            print("\(self.implementation.TAG) Download called without version")
            call.reject("Download called without version")
            return
        }
        let url = URL(string: urlString)
        print("\(self.implementation.TAG) Downloading \(url!)")
        do {
            let res = try implementation.download(url: url!, version: version)
            call.resolve(res.toJSON())
        } catch {
            call.reject("download failed", error.localizedDescription)
        }
    }

    private func _reload() -> Bool {
        guard let bridge = self.bridge else { return false }
        let id = self.implementation.getCurrentBundleId()
        let destHot = self.implementation.getPathHot(id: id)
        print("\(self.implementation.TAG) Reloading \(id)")
        if let vc = bridge.viewController as? CAPBridgeViewController {
            vc.setServerBasePath(path: destHot.path)
            self.checkAppReady()
            return true
        }
        return false
    }
    
    @objc func reload(_ call: CAPPluginCall) {
        if (self._reload()) {
            call.resolve()
        } else {
            call.reject("Reload failed")
            print("\(self.implementation.TAG) Reload failed")
        }
    }

    @objc func next(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            print("\(self.implementation.TAG) Next called without id")
            call.reject("Next called without id")
            return
        }

        print("\(self.implementation.TAG) Setting next active id \(id)")
        if (!self.implementation.setNextVersion(next: id)) {
            call.reject("Set next version failed. id \(id) does not exist.")
        } else {
            call.resolve(self.implementation.getBundleInfo(id: id).toJSON())
        }
    }
    
    @objc func set(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            print("\(self.implementation.TAG) Set called without id")
            call.reject("Set called without id")
            return
        }
        let res = implementation.set(id: id)
        print("\(self.implementation.TAG) Set active bundle: \(id)")
        if (!res) {
            print("\(self.implementation.TAG) Bundle successfully set to: \(id) ")
            call.reject("Update failed, id \(id) doesn't exist")
        } else {
            self.reload(call)
        }
    }

    @objc func delete(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else {
            print("\(self.implementation.TAG) Delete called without version")
            call.reject("Delete called without id")
            return
        }
        let res = implementation.delete(id: id)
        if (res) {
            call.resolve()
        } else {
            call.reject("Delete failed, id \(id) doesn't exist")
        }
    }

    @objc func list(_ call: CAPPluginCall) {
        let res = implementation.list()
        var resArr: [[String: String]] = []
        for v in res {
            resArr.append(v.toJSON())
        }
        call.resolve([
            "versions": resArr
        ])
    }

    @objc func _reset(toAutoUpdate: Bool) -> Bool {
        guard let bridge = self.bridge else { return false }
        if let vc = bridge.viewController as? CAPBridgeViewController {
            self.implementation.reset()
            
            let LatestVersionAutoUpdate = UserDefaults.standard.string(forKey: "LatestVersionAutoUpdate") ?? ""
            let LatestVersionNameAutoUpdate = UserDefaults.standard.string(forKey: "LatestVersionNameAutoUpdate") ?? ""
            if(toAutoUpdate && LatestVersionAutoUpdate != "" && LatestVersionNameAutoUpdate != "") {
                let res = implementation.set(id: LatestVersionNameAutoUpdate)
                return res && self._reload()
            }
            implementation.reset()
            vc.setServerBasePath(path: "")
            DispatchQueue.main.async {
                vc.loadView()
                vc.viewDidLoad()
                print("\(self.implementation.TAG) Reset to builtin version")
            }
            return true
        }
        return false
    }

    @objc func reset(_ call: CAPPluginCall) {
        let toAutoUpdate = call.getBool("toAutoUpdate") ?? false
        if (self._reset(toAutoUpdate: toAutoUpdate)) {
            return call.resolve()
        }
        call.reject("\(self.implementation.TAG) Reset failed")
    }
    
    @objc func current(_ call: CAPPluginCall) {
        let bundle: BundleInfo = self.implementation.getCurrentBundle()
        call.resolve([
            "bundle": bundle.toJSON(),
            "native": self.currentVersionNative
        ])
    }

    @objc func notifyAppReady(_ call: CAPPluginCall) {
        print("\(self.implementation.TAG) Current bundle loaded successfully. ['notifyAppReady()' was called]")
        let version = self.implementation.getCurrentBundle()
        self.implementation.commit(bundle: version)
        call.resolve()
    }
    
    @objc func setDelay(_ call: CAPPluginCall) {
        guard let delay = call.getBool("delay") else {
            print("\(self.implementation.TAG) setDelay called without delay")
            call.reject("setDelay called without delay")
            return
        }
        UserDefaults.standard.set(delay, forKey: "delayUpdate")
        call.resolve()
    }
    
    private func _isAutoUpdateEnabled() -> Bool {
        return self.autoUpdate && self.autoUpdateUrl != ""
    }

    @objc func isAutoUpdateEnabled(_ call: CAPPluginCall) {
        call.resolve([
            "enabled": self._isAutoUpdateEnabled()
        ])
    }

    func checkAppReady() {
        self.appReadyCheck?.cancel()
        self.appReadyCheck = DispatchWorkItem(block: {
            self.DeferredNotifyAppReadyCheck()
        })
        print("\(self.implementation.TAG) Wait for \(self.appReadyTimeout) ms, then check for notifyAppReady")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.appReadyTimeout), execute: self.appReadyCheck!)
    }

    func DeferredNotifyAppReadyCheck() {
        // Automatically roll back to fallback version if notifyAppReady has not been called yet
        let current: BundleInfo = self.implementation.getCurrentBundle()
        if(current.isBuiltin()) {
            print("\(self.implementation.TAG) Built-in bundle is active. Nothing to do.")
            return
        }

        if(BundleStatus.SUCCESS.localizedString != current.getStatus()) {
            print("\(self.implementation.TAG) notifyAppReady was not called, roll back current bundle: \(current.toString())")
            self.implementation.rollback(bundle: current)
            let res = self._reset(toAutoUpdate: true)
            if (!res) {
                return
            }
        } else {
            print("\(self.implementation.TAG) notifyAppReady was called. This is fine: \(current.toString())")
        }
        self.appReadyCheck = nil
    }

    @objc func appMovedToForeground() {
        if (self._isAutoUpdateEnabled()) {
            DispatchQueue.global(qos: .background).async {
                print("\(self.implementation.TAG) Check for update via \(self.autoUpdateUrl)")
                let url = URL(string: self.autoUpdateUrl)!
                let res = self.implementation.getLatest(url: url)
                if (res == nil) {
                    print("\(self.implementation.TAG) No result found in \(self.autoUpdateUrl)")
                    return
                }
                guard let downloadUrl = URL(string: res?.url ?? "") else {
                    print("\(self.implementation.TAG) Error \(res?.message ?? "Unknow error")")
                    if (res?.major == true) {
                        self.notifyListeners("majorAvailable", data: ["version": res?.version ?? "0.0.0"])
                    }
                    return
                }
                let current = self.implementation.getCurrentBundle()
                let latestVersionName = res?.version
                if (latestVersionName != nil && latestVersionName != "" && current.getVersionName() != latestVersionName) {
                    let latest = self.implementation.getBundleInfoByVersionName(version: latestVersionName!)
                    if (latest != nil) {
                        if(latest!.isErrorStatus()) {
                            print("\(self.implementation.TAG) Latest version already exists, and is in error state. Aborting update.")
                            return
                        }
                        if(latest!.isDownloaded()){
                            print("\(self.implementation.TAG) Latest version already exists and download is NOT required. Update will occur next time app moves to background.")
                            let _ = self.implementation.setNextVersion(next: latest!.getId())
                            return
                        }
                    }

                    do {
                        print("\(self.implementation.TAG) New bundle: \(latestVersionName!) found. Current is: \(current.getVersionName()). Update will occur next time app moves to background.")
                        let next = try self.implementation.download(url: downloadUrl, version: latestVersionName!)

                        let _ = self.implementation.setNextVersion(next: next.getId())
                    } catch {
                        print("\(self.implementation.TAG) Error downloading file", error.localizedDescription)
                    }
                }
            }
        }

        self.checkAppReady()
    }

    @objc func appMovedToBackground() {
        print("\(self.implementation.TAG) Check for waiting update")
        let delayUpdate = UserDefaults.standard.bool(forKey: "delayUpdate")
        UserDefaults.standard.set(false, forKey: "delayUpdate")
        if (delayUpdate) {
            print("\(self.implementation.TAG) Update delayed to next backgrounding")
            return
        }

        let fallback: BundleInfo = self.implementation.getFallbackVersion()
        let current: BundleInfo = self.implementation.getCurrentBundle()
        let next: BundleInfo? = self.implementation.getNextVersion()

        let success: Bool = current.getStatus() == BundleStatus.SUCCESS.localizedString

        print("\(self.implementation.TAG) Fallback bundle is: \(fallback.toString())")
        print("\(self.implementation.TAG) Current bundle is: \(current.toString())")

        if (next != nil && !next!.isErrorStatus() && (next!.getVersionName() != current.getVersionName())) {
            print("\(self.implementation.TAG) Next bundle is: \(next!.toString())")
            if (self.implementation.set(bundle: next!) && self._reload()) {
                print("\(self.implementation.TAG) Updated to bundle: \(next!)")
                let _ = self.implementation.setNextVersion(next: Optional<String>.none)
            } else {
                print("\(self.implementation.TAG) Updated to bundle: \(next!) Failed!")
            }
        } else if (!success) {
            // There is a no next version, and the current version has failed

            if(!current.isBuiltin()) {
                // Don't try to roll back the builtin version. Nothing we can do.

                self.implementation.rollback(bundle: current)
                
                print("\(self.implementation.TAG) Update failed: 'notifyAppReady()' was never called.")
                print("\(self.implementation.TAG) Version: \(current.toString()), is in error state.")
                print("\(self.implementation.TAG) Will fallback to: \(fallback.toString()) on application restart.")
                print("\(self.implementation.TAG) Did you forget to call 'notifyAppReady()' in your Capacitor App code?")

                self.notifyListeners("updateFailed", data: [
                    "bundle": current.toJSON()
                ])
                self.implementation.sendStats(action: "revert", bundle: current)
                if (!fallback.isBuiltin() && !(fallback == current)) {
                    let res = self.implementation.set(bundle: fallback)
                    if (res && self._reload()) {
                        print("\(self.implementation.TAG) Revert to bundle: \(fallback.toString())")
                    } else {
                        print("\(self.implementation.TAG) Revert to bundle: \(fallback.toString()) Failed!")
                    }
                } else {
                    if (self._reset(toAutoUpdate: false)) {
                        print("\(self.implementation.TAG) Reverted to 'builtin' bundle.")
                    }
                }

                if (self.autoDeleteFailed) {
                    print("\(self.implementation.TAG) Deleting failing bundle: \(current.toString())")
                    let res = self.implementation.delete(id: current.getId())
                    if (!res) {
                        print("\(self.implementation.TAG) Delete version deleted: \(current.toString())")
                    } else {
                        print("\(self.implementation.TAG) Failed to delete failed bundle: \(current.toString())")
                    }
                }
            } else {
                // Nothing we can/should do by default if the 'builtin' bundle fails to call 'notifyAppReady()'.
            }
        } else if (!fallback.isBuiltin()) {
            // There is a no next version, and the current version has succeeded
            self.implementation.commit(bundle: current)

            if(self.autoDeletePrevious) {
                print("\(self.implementation.TAG) Version successfully loaded: \(current.toString())")
                let res = self.implementation.delete(id: fallback.getId())
                if (res) {
                    print("\(self.implementation.TAG) Deleted previous bundle: \(fallback.toString())")
                } else {
                    print("\(self.implementation.TAG) Failed to delete previous bundle: \(fallback.toString())")
                }
            }
        }
    }
}
