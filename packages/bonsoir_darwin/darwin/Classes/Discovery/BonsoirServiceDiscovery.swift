#if canImport(Flutter)
    import Flutter
#endif
#if canImport(FlutterMacOS)
    import FlutterMacOS
#endif
import Network

/// Allows to find net services on local network.
@available(iOS 13.0, macOS 10.15, *)
class BonsoirServiceDiscovery: BonsoirAction {
    /// The type we're listening to.
    private let type: String
    
    /// The current browser instance.
    private let browser: NWBrowser
    
    /// Contains all found services.
    private var services: [BonsoirService] = []
    
    /// Contains all services we're currently resolving.
    private var pendingResolution: [DNSServiceRef] = []
    
    /// Initializes this class.
    public init(id: Int, printLogs: Bool, onDispose: @escaping () -> Void, messenger: FlutterBinaryMessenger, type: String) {
        self.type = type
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: .tcp)
        super.init(id: id, action: "discovery", printLogs: printLogs, onDispose: onDispose, messenger: messenger)
        browser.stateUpdateHandler = stateHandler
        browser.browseResultsChangedHandler = browseHandler
    }
    
    /// Finds a service amongst discovered services.
    private func findService(_ name: String, _ type: String? = nil) -> BonsoirService? {
        return services.first(where: {$0.name == name && (type == nil || $0.type == type)})
    }
    
    /// Handles state changes.
    func stateHandler(_ newState: NWBrowser.State) {
        switch newState {
        case .ready:
            onSuccess("discoveryStarted", "Bonsoir discovery started : \(type)")
        case .failed(let error):
            onError("Bonsoir has encountered an error during discovery : \(error)", error)
            dispose()
        case .cancelled:
            onSuccess("discoveryStopped", "Bonsoir discovery stopped : \(type)")
            dispose()
        default:
            break
        }
    }
    
    /// Handles the browsing of services.
    func browseHandler(_ newResults: Set<NWBrowser.Result>, _ changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            switch change {
            case .added(let result):
                if case .service(let name, let type, _, _) = result.endpoint {
                    var service = findService(name, type)
                    if service != nil {
                        break
                    }
                    service = BonsoirService(name: name, type: type, port: 0, host: nil, attributes: [:])
                    if case .bonjour(let records) = result.metadata {
                        service!.attributes = records.dictionary
                    }
                    onSuccess("discoveryServiceFound", "Bonsoir has found a service : \(service!)", service)
                    services.append(service!)
                }
            case .removed(let result):
                if case .service(let name, let type, _, _) = result.endpoint {
                    guard let service = findService(name, type) else {
                        break
                    }
                    onSuccess("discoveryServiceLost", "A Bonsoir service has been lost : \(service)", service)
                    if let index = self.services.firstIndex(where: { $0 === service }) {
                        self.services.remove(at: index)
                    }
                }
            case .changed(let old, let new, _):
                if case .service(let newName, let newType, _, _) = new.endpoint {
                    if case .service(let oldName, let oldType, _, _) = old.endpoint {
                        guard let service = findService(oldName) else {
                            break
                        }
                        var newAttributes: [String: String]
                        if case .bonjour(let newRecords) = new.metadata {
                            newAttributes = newRecords.dictionary
                        } else {
                            newAttributes = service.attributes
                        }
                        if oldName == newName && oldType == newType && newAttributes == service.attributes {
                            break
                        }
                        onSuccess("discoveryServiceLost", "A Bonsoir service has changed \(service)", service)
                        service.name = newName
                        service.type = newType
                        service.attributes = newAttributes
                        onSuccess("discoveryServiceFound", "New service is \(service)", service)
                    }
                }
            default:
                break
            }
        }
    }
    
    /// Resolves a service.
    public func resolveService(name: String, type: String) -> Bool {
        guard let service = findService(name, type) else {
            onError("Trying to resolve an undiscovered service : \(name)")
            return false
        }
        var sdRef: DNSServiceRef? = nil
        let error = DNSServiceResolve(&sdRef, 0, 0, name, type, "local.", BonsoirServiceDiscovery.resolveCallback, Unmanaged.passUnretained(self).toOpaque())
        if error != kDNSServiceErr_NoError {
            onSuccess("discoveryServiceResolveFailed", "Bonsoir has failed to resolve a service : \(error)", service)
            stopResolution(sdRef: sdRef, remove: false)
            return false
        }
        pendingResolution.append(sdRef!)
        DNSServiceProcessResult(sdRef)
        return true
    }
    
    /// Stops the resolution of the given service.
    private func stopResolution(sdRef: DNSServiceRef?, remove: Bool = true) {
        if remove, let index = self.pendingResolution.firstIndex(where: { $0 == sdRef }) {
            self.pendingResolution.remove(at: index)
        }
        DNSServiceRefDeallocate(sdRef)
    }
    
    /// Starts the discovery.
    public func start() {
        browser.start(queue: .main)
    }
    
    override public func dispose() {
        for sdRef in pendingResolution {
            stopResolution(sdRef: sdRef, remove: false)
        }
        pendingResolution.removeAll()
        services.removeAll()
        if [.setup, .ready].contains(browser.state) {
            browser.cancel()
        }
        super.dispose()
    }
    
    /// Callback triggered by`DNSServiceResolve`.
    private static let resolveCallback: DNSServiceResolveReply = ({ sdRef, flags, interfaceIndex, errorCode, fullName, hosttarget, port, txtLen, txtRecord, context in
        let discovery = Unmanaged<BonsoirServiceDiscovery>.fromOpaque(context!).takeUnretainedValue()
        var service: BonsoirService?
        if fullName != nil {
            let parts = String(cString: fullName!).components(separatedBy: ".")
            if parts.count == 4 || parts.count == 5 {
                service = discovery.findService(unescapeAscii(parts[0]), parts[1] + "." + parts[2])
            }
        }
        if service != nil && errorCode == kDNSServiceErr_NoError {
            if hosttarget != nil {
                service!.host = String(cString: hosttarget!)
            }
            service!.port = Int(CFSwapInt16BigToHost(port))
            discovery.onSuccess("discoveryServiceResolved", "Bonsoir has resolved a service : \(service!)", service)
        } else {
            if (service == nil) {
                discovery.onError("Bonsoir has failed to resolve a service : \(errorCode)", errorCode)
             } else {
                discovery.onSuccess("discoveryServiceResolveFailed", "Bonsoir has failed to resolve a service : \(errorCode)", service)
            }
        }
        discovery.stopResolution(sdRef: sdRef, remove: sdRef != nil)
    })
    
    /// Allows to unescape services FQDN.
    private static func unescapeAscii(_ input: String) -> String {
        var result = ""
        var i = 0
        while i < input.count {
            if input[i] == "\\" && i + 1 < input.count {
                var asciiCode = ""
                var j = 1
                while j < 4 {
                    if i + j >= input.count || Int(String(input[i + j])) == nil {
                        break
                    }
                    asciiCode += String(input[i + j])
                    j += 1
                }
                if let code = Int(asciiCode), let unicodeScalar = UnicodeScalar(code) {
                    result += String(unicodeScalar)
                }
                i += (j - 1)
            } else {
                result += String(input[i])
            }
            
            i += 1
        }
        return result
    }
}

extension String {
    var isNumeric: Bool {
        return !isEmpty && rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil
    }
    
    subscript (i: Int) -> String {
        return self[i ..< i + 1]
    }
    
    func substring(fromIndex: Int) -> String {
        return self[min(fromIndex, count) ..< count]
    }
    
    func substring(toIndex: Int) -> String {
        return self[0 ..< max(0, toIndex)]
    }
    
    subscript (r: Range<Int>) -> String {
        let range = Range(uncheckedBounds: (lower: max(0, min(count, r.lowerBound)),
                                            upper: min(count, max(0, r.upperBound))))
        let start = index(startIndex, offsetBy: range.lowerBound)
        let end = index(start, offsetBy: range.upperBound - range.lowerBound)
        return String(self[start ..< end])
    }
}