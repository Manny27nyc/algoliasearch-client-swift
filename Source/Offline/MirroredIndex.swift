//
//  Copyright (c) 2015-2016 Algolia
//  http://www.algolia.com/
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import AlgoliaSearchOfflineCore
import Foundation


/// A data selection query, used to select data to be mirrored locally by a `MirroredIndex`.
///
@objc open class DataSelectionQuery: NSObject {
    /// Query used to select data.
    @objc open let query: Query
    
    /// Maximum number of objects to retrieve with this query.
    @objc open let maxObjects: Int

    /// Create a new data selection query.
    @objc public init(query: Query, maxObjects: Int) {
        self.query = query
        self.maxObjects = maxObjects
    }
    
    override open func isEqual(_ object: Any?) -> Bool {
        guard let rhs = object as? DataSelectionQuery else {
            return false
        }
        return self.query == rhs.query && self.maxObjects == rhs.maxObjects
    }
}


/// An online index that can also be mirrored locally.
///
/// When created, an instance of this class has its `mirrored` flag set to false, and behaves like a normal,
/// online `Index`. When the `mirrored` flag is set to true, the index becomes capable of acting upon local data.
///
/// + Warning: It is a programming error to call methods acting on the local data when `mirrored` is false. Doing so
/// will result in an assertion error being raised.
///
/// Native resources are lazily instantiated at the first method call requiring them. They are released when the
/// object is released. Although the client guards against concurrent accesses, it is strongly discouraged
/// to create more than one `MirroredIndex` instance pointing to the same index, as that would duplicate
/// native resources.
///
/// + Note: Requires Algolia's SDK. The `OfflineClient.enableOfflineMode(...)` method must be called with a valid
/// license key prior to calling any offline-related method.
///
/// ### Request strategy
///
/// When the index is mirrored and the device is online, it becomes possible to transparently switch between online and
/// offline requests. There is no single best strategy for that, because it depends on the use case and the current
/// network conditions. You can choose the strategy through the `requestStrategy` property. The default is
/// `FallbackOnFailure`, which will always target the online API first, then fallback to the offline mirror in case of
/// failure (including network unavailability).
///
/// + Note: If you want to explicitly target either the online API or the offline mirror, doing so is always possible
/// using the `searchOnline(...)` or `searchOffline(...)` methods.
///
/// + Note: The strategy applies both to `search(...)` and `searchDisjunctiveFaceting(...)`.
///
@objc open class MirroredIndex : Index {
    
    // MARK: Constants
    
    /// Notification sent when the sync has started.
    @objc open static let SyncDidStartNotification = "AlgoliaSearch.MirroredIndex.SyncDidStartNotification"
    
    /// Notification sent when the sync has finished.
    @objc open static let SyncDidFinishNotification = "AlgoliaSearch.MirroredIndex.SyncDidFinishNotification"
    
    /// Notification user info key used to pass the error, when an error occurred during the sync.
    @objc open static let SyncErrorKey = "AlgoliaSearch.MirroredIndex.SyncErrorKey"
    
    /// Default minimum delay between two syncs.
    @objc open static let DefaultDelayBetweenSyncs: TimeInterval = 60 * 60 * 24 // 1 day

    /// Key used to indicate the origin of results in the returned JSON.
    @objc open static let JSONKeyOrigin = "origin"
    
    /// Value for `JSONKeyOrigin` indicating that the results come from the local mirror.
    @objc open static let JSONValueOriginLocal = "local"
    
    /// Value for `JSONKeyOrigin` indicating that the results come from the online API.
    @objc open static let JSONValueOriginRemote = "remote"

    // ----------------------------------------------------------------------
    // MARK: Properties
    // ----------------------------------------------------------------------
    
    /// The offline client used by this index.
    @objc open var offlineClient: OfflineClient {
        // IMPLEMENTATION NOTE: Could not find a way to implement proper covariant properties in Swift.
        return self.client as! OfflineClient
    }
    
    /// The local index mirroring this remote index (lazy instantiated, only if mirroring is activated).
    lazy var localIndex: ASLocalIndex! = ASLocalIndex(dataDir: self.offlineClient.rootDataDir, appID: self.client.appID, indexName: self.indexName)
    
    /// The mirrored index settings.
    let mirrorSettings = MirrorSettings()
    
    /// Whether the index is mirrored locally. Default = false.
    @objc open var mirrored: Bool = false {
        didSet {
            if (mirrored) {
                do {
                    try FileManager.default.createDirectory(atPath: self.indexDataDir, withIntermediateDirectories: true, attributes: nil)
                } catch _ {
                    // Ignore
                }
                mirrorSettings.load(self.mirrorSettingsFilePath)
            }
        }
    }
    
    /// Data selection queries.
    @objc open var dataSelectionQueries: [DataSelectionQuery] {
        get {
            return mirrorSettings.queries
        }
        set {
            if (mirrorSettings.queries != newValue) {
                mirrorSettings.queries = newValue
                mirrorSettings.queriesModificationDate = Date()
                mirrorSettings.save(mirrorSettingsFilePath)
            }
        }
    }
    
    /// Minimum delay between two syncs.
    @objc open var delayBetweenSyncs: TimeInterval = DefaultDelayBetweenSyncs
    
    /// Date of the last successful sync, or nil if the index has never been successfully synced.
    @objc open var lastSuccessfulSyncDate: Date? {
        return mirrorSettings.lastSyncDate
    }
    
    /// Error encountered by the current/last sync (if any).
    @objc open fileprivate(set) var syncError : NSError?

    // ----------------------------------------------------------------------
    // MARK: - Init
    // ----------------------------------------------------------------------
    
    @objc override internal init(client: Client, indexName: String) {
        assert(client is OfflineClient);
        super.init(client: client, indexName: indexName)
    }
    
    // ----------------------------------------------------------------------
    // MARK: - Sync
    // ----------------------------------------------------------------------

    /// Syncing indicator.
    ///
    /// + Note: To prevent concurrent access to this variable, we always access it from the build (serial) queue.
    ///
    fileprivate var syncing: Bool = false
    
    /// Path to the temporary directory for the current sync.
    fileprivate var tmpDir : String!
    
    /// The path to the settings file.
    fileprivate var settingsFilePath: String!
    
    /// Paths to object files/
    fileprivate var objectsFilePaths: [String]!
    
    /// The current object file index. Object files are named `${i}.json`, where `i` is automatically incremented.
    fileprivate var objectFileIndex = 0
    
    /// The operation to build the index.
    /// NOTE: We need to store it because its dependencies are modified dynamically.
    fileprivate var buildIndexOperation: Operation!
    
    /// Path to the persistent mirror settings.
    fileprivate var mirrorSettingsFilePath: String {
        get { return "\(self.indexDataDir)/mirror.plist" }
    }
    
    /// Path to this index's offline data.
    fileprivate var indexDataDir: String {
        get { return "\(self.offlineClient.rootDataDir)/\(self.client.appID)/\(self.indexName)" }
    }
    
    /// Timeout for data synchronization queries.
    /// There is no need to use a too short timeout in this case: we don't need real-time performance, so failing
    /// too soon would only increase the likeliness of a failure.
    fileprivate let SYNC_TIMEOUT: TimeInterval = 30

    /// Add a data selection query to the local mirror.
    /// The query is not run immediately. It will be run during the subsequent refreshes.
    ///
    /// + Precondition: Mirroring must have been activated on this index (see the `mirrored` property).
    ///
    @objc open func addDataSelectionQuery(_ query: DataSelectionQuery) {
        assert(mirrored);
        mirrorSettings.queries.append(query)
        mirrorSettings.queriesModificationDate = Date()
        mirrorSettings.save(self.mirrorSettingsFilePath)
    }
    
    /// Add any number of data selection queries to the local mirror.
    /// The query is not run immediately. It will be run during the subsequent refreshes.
    ///
    /// + Precondition: Mirroring must have been activated on this index (see the `mirrored` property).
    ///
    @objc open func addDataSelectionQueries(_ queries: [DataSelectionQuery]) {
        assert(mirrored);
        mirrorSettings.queries.append(contentsOf: queries)
        mirrorSettings.queriesModificationDate = Date()
        mirrorSettings.save(self.mirrorSettingsFilePath)
    }

    /// Launch a sync.
    /// This unconditionally launches a sync, unless one is already running.
    ///
    /// + Precondition: Mirroring must have been activated on this index (see the `mirrored` property).
    ///
    @objc open func sync() {
        assert(self.mirrored, "Mirroring not activated on this index")
        offlineClient.buildQueue.addOperation() {
            self._sync()
        }
    }

    /// Launch a sync if needed.
    /// This takes into account the delay between syncs.
    ///
    /// + Precondition: Mirroring must have been activated on this index (see the `mirrored` property).
    ///
    @objc open func syncIfNeeded() {
        assert(self.mirrored, "Mirroring not activated on this index")
        if self.isSyncDelayExpired() || self.isMirrorSettingsDirty() {
            offlineClient.buildQueue.addOperation() {
                self._sync()
            }
        }
    }
    
    fileprivate func isSyncDelayExpired() -> Bool {
        let currentDate = Date()
        if let lastSyncDate = mirrorSettings.lastSyncDate {
            return currentDate.timeIntervalSince(lastSyncDate as Date) > self.delayBetweenSyncs
        } else {
            return true
        }
    }
    
    fileprivate func isMirrorSettingsDirty() -> Bool {
        if let queriesModificationDate = mirrorSettings.queriesModificationDate {
            if let lastSyncDate = lastSuccessfulSyncDate {
                return queriesModificationDate.compare(lastSyncDate) == .orderedDescending
            } else {
                return true
            }
        } else {
            return false
        }
    }
    
    /// Refresh the local mirror.
    ///
    /// WARNING: Calls to this method must be synchronized by the caller.
    ///
    fileprivate func _sync() {
        assert(!Thread.isMainThread) // make sure it's run in the background
        assert(OperationQueue.current == offlineClient.buildQueue) // ensure serial calls
        assert(!self.dataSelectionQueries.isEmpty)

        // If already syncing, abort.
        if syncing {
            return
        }
        syncing = true

        // Notify observers.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name(rawValue: MirroredIndex.SyncDidStartNotification), object: self)
        }

        // Create temporary directory.
        do {
            tmpDir = NSTemporaryDirectory() + "/algolia/" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true, attributes: nil)
        } catch _ {
            NSLog("ERROR: Could not create temporary directory '%@'", tmpDir)
        }
        
        // NOTE: We use `NSOperation`s to handle dependencies between tasks.
        syncError = nil
        
        // Task: Download index settings.
        // TODO: Factorize query construction with regular code.
        let path = "1/indexes/\(urlEncodedIndexName)/settings"
        let settingsOperation = client.newRequest(.GET, path: path, body: nil, hostnames: client.readHosts, isSearchQuery: false) {
            (json, error) in
            if error != nil {
                self.syncError = error
            } else {
                assert(json != nil)
                // Write results to disk.
                if let data = try? JSONSerialization.data(withJSONObject: json!, options: []) {
                    self.settingsFilePath = "\(self.tmpDir)/settings.json"
                    try? data.write(to: URL(fileURLWithPath: self.settingsFilePath), options: [])
                    return // all other paths go to error
                } else {
                    self.syncError = NSError(domain: Client.ErrorDomain, code: StatusCode.unknown.rawValue, userInfo: [NSLocalizedDescriptionKey: "Could not write index settings"])
                }
            }
            assert(self.syncError != nil) // we should reach this point only in case of error (see above)
        }
        offlineClient.buildQueue.addOperation(settingsOperation)
        
        // Task: build the index using the downloaded files.
        buildIndexOperation = BlockOperation() {
            if self.syncError == nil {
                let status = self.localIndex.build(fromSettingsFile: self.settingsFilePath, objectFiles: self.objectsFilePaths, clearIndex: true)
                if status != 200 {
                    self.syncError = NSError(domain: Client.ErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not build local index"])
                } else {
                    // Remember the sync's date
                    self.mirrorSettings.lastSyncDate = Date()
                    self.mirrorSettings.save(self.mirrorSettingsFilePath)
                }
            }
            self._syncFinished()
        }
        buildIndexOperation.name = "Build \(self)"
        // Make sure this task is run after the settings task.
        buildIndexOperation.addDependency(settingsOperation)

        // Tasks: Perform data selection queries.
        objectFileIndex = 0
        objectsFilePaths = []
        for dataSelectionQuery in mirrorSettings.queries {
            doBrowseQuery(dataSelectionQuery, browseQuery: dataSelectionQuery.query, objectCount: 0)
        }
        
        // Finally add the build index operation to the queue, now that dependencies are set up.
        offlineClient.buildQueue.addOperation(buildIndexOperation)
    }
    
    // Auxiliary function, called:
    // - once synchronously, to initiate the browse;
    // - from 0 to many times asynchronously, to continue browsing.
    //
    fileprivate func doBrowseQuery(_ dataSelectionQuery: DataSelectionQuery, browseQuery: Query, objectCount currentObjectCount: Int) {
        objectFileIndex += 1
        let currentObjectFileIndex = objectFileIndex
        let path = "1/indexes/\(urlEncodedIndexName)/browse"
        let operation = client.newRequest(.POST, path: path, body: ["params": browseQuery.build()], hostnames: client.readHosts, isSearchQuery: false) {
            (json, error) in
            if error != nil {
                self.syncError = error
            } else {
                assert(json != nil)
                // Fetch cursor from data.
                let cursor = json!["cursor"] as? String
                if let hits = json!["hits"] as? [JSONObject] {
                    // Update object count.
                    let newObjectCount = currentObjectCount + hits.count
                    
                    // Write results to disk.
                    if let data = try? JSONSerialization.data(withJSONObject: json!, options: []) {
                        let objectFilePath = "\(self.tmpDir)/\(currentObjectFileIndex).json"
                        self.objectsFilePaths.append(objectFilePath)
                        try? data.write(to: URL(fileURLWithPath: objectFilePath), options: [])
                        
                        // Chain if needed.
                        if cursor != nil && newObjectCount < dataSelectionQuery.maxObjects {
                            self.doBrowseQuery(dataSelectionQuery, browseQuery: Query(parameters: ["cursor": cursor!]), objectCount: newObjectCount)
                        }
                        return // all other paths go to error
                    } else {
                        self.syncError = NSError(domain: Client.ErrorDomain, code: StatusCode.unknown.rawValue, userInfo: [NSLocalizedDescriptionKey: "Could not write hits"])
                    }
                } else {
                    self.syncError = NSError(domain: Client.ErrorDomain, code: StatusCode.invalidResponse.rawValue, userInfo: [NSLocalizedDescriptionKey: "No hits in server response"])
                }
            }
            assert(self.syncError != nil) // we should reach this point only in case of error (see above)
        }
        offlineClient.buildQueue.addOperation(operation)
        buildIndexOperation.addDependency(operation)
    }

    /// Wrap-up method, to be called at the end of each sync, *whatever the result*.
    ///
    /// WARNING: Calls to this method must be synchronized by the caller.
    ///
    fileprivate func _syncFinished() {
        assert(OperationQueue.current == offlineClient.buildQueue) // ensure serial calls

        // Clean-up.
        do {
            try FileManager.default.removeItem(atPath: tmpDir)
        } catch _ {
            // Ignore error
        }
        tmpDir = nil
        settingsFilePath = nil
        objectsFilePaths = nil
        buildIndexOperation = nil
        
        // Mark the sync as finished.
        self.syncing = false
        
        // Notify observers.
        DispatchQueue.main.async {
            var userInfo: [String: Any]? = nil
            if self.syncError != nil {
                userInfo = [MirroredIndex.SyncErrorKey: self.syncError!]
            }
            NotificationCenter.default.post(name: Notification.Name(rawValue: MirroredIndex.SyncDidFinishNotification), object: self, userInfo: userInfo)
        }
    }
    
    // ----------------------------------------------------------------------
    // MARK: - Search
    // ----------------------------------------------------------------------
    
    /// Strategy to choose between online and offline search.
    ///
    @objc public enum Strategy: Int {
        /// Search online only.
        /// The search will fail when the API can't be reached.
        ///
        /// + Note: You might consider that this defeats the purpose of having a mirror in the first place... But this
        /// is intended for applications wanting to manually manage their policy.
        ///
        case onlineOnly = 0

        /// Search offline only.
        /// The search will fail when the offline mirror has not yet been synced.
        ///
        case offlineOnly = 1
        
        /// Search online, then fallback to offline on failure.
        /// Please note that when online, this is likely to hit the request timeout on *every host* before failing.
        ///
        case fallbackOnFailure = 2
        
        /// Fallback after a certain timeout.
        /// Will first try an online request, but fallback to offline in case of failure or when a timeout has been
        /// reached, whichever comes first.
        ///
        /// The timeout can be set through the `offlineFallbackTimeout` property.
        ///
        case fallbackOnTimeout = 3
    }
    
    /// Strategy to use for offline fallback. Default = `FallbackOnFailure`.
    @objc open var requestStrategy: Strategy = .fallbackOnFailure
    
    /// Timeout used to control offline fallback.
    ///
    /// + Note: Only used by the `FallbackOnTimeout` strategy.
    ///
    @objc open var offlineFallbackTimeout: TimeInterval = 1.0

    /// A mixed online/offline request.
    /// This request encapsulates two concurrent online and offline requests, to optimize response time.
    ///
    fileprivate class OnlineOfflineOperation: AsyncOperation {
        fileprivate let index: MirroredIndex
        let completionHandler: CompletionHandler
        fileprivate var onlineRequest: Operation?
        fileprivate var offlineRequest: Operation?
        fileprivate var mayRunOfflineRequest: Bool = true
        
        init(index: MirroredIndex, completionHandler: @escaping CompletionHandler) {
            assert(index.mirrored)
            self.index = index
            self.completionHandler = completionHandler
        }
        
        override func start() {
            // WARNING: All callbacks must run sequentially; we cannot afford race conditions between them.
            // Since most methods use the main thread for callbacks, we have to use it as well.
            
            // If the strategy is "offline only", well, go offline straight away.
            if index.requestStrategy == .offlineOnly {
                startOffline()
            }
            // Otherwise, always launch an online request.
            else {
                if index.requestStrategy == .onlineOnly || !index.localIndex.exists() {
                    mayRunOfflineRequest = false
                }
                startOnline()
            }
            if index.requestStrategy == .fallbackOnTimeout && mayRunOfflineRequest {
                // Schedule an offline request to start after a certain delay.
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(index.offlineFallbackTimeout * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
                    [weak self] in
                    // WARNING: Because dispatched blocks cannot be cancelled, and to avoid increasing the lifetime of
                    // the operation by the timeout delay, we do not retain self. => Gracefully fail if the operation
                    // has already finished.
                    guard let this = self else { return }
                    if this.mayRunOfflineRequest {
                        this.startOffline()
                    }
                }
            }
        }
        
        fileprivate func startOnline() {
            // Avoid launching the request twice.
            if onlineRequest != nil {
                return
            }
            onlineRequest = startOnlineRequest({
                [unowned self] // works because the operation is enqueued and retained by the queue
                (content, error) in
                // In case of transient error, run an offline request.
                if error != nil && error!.isTransient() && self.mayRunOfflineRequest {
                    self.startOffline()
                }
                // Otherwise, just return the online results.
                else {
                    self.cancelOffline()
                    self.callCompletion(content, error: error)
                }
            })
        }
        
        fileprivate func startOffline() {
            // NOTE: If we reach this handler, it means the offline request has not been cancelled.
            assert(mayRunOfflineRequest)
            // Avoid launching the request twice.
            if offlineRequest != nil {
                return
            }
            offlineRequest = startOfflineRequest({
                [unowned self] // works because the operation is enqueued and retained by the queue
                (content, error) in
                self.onlineRequest?.cancel()
                self.callCompletion(content, error: error)
            })
        }
        
        fileprivate func cancelOffline() {
            // Flag the offline request as obsolete.
            mayRunOfflineRequest = false;
            // Cancel the offline request if already running.
            offlineRequest?.cancel();
            offlineRequest = nil
        }
        
        override func cancel() {
            if !isCancelled {
                onlineRequest?.cancel()
                cancelOffline()
                super.cancel()
            }
        }
        
        fileprivate func callCompletion(_ content: JSONObject?, error: NSError?) {
            if _finished {
                return
            }
            if !_cancelled {
                completionHandler(content, error)
            }
            finish()
        }
        
        func startOnlineRequest(_ completionHandler: @escaping CompletionHandler) -> Operation {
            preconditionFailure("To be implemented by derived classes")
        }

        func startOfflineRequest(_ completionHandler: @escaping CompletionHandler) -> Operation {
            preconditionFailure("To be implemented by derived classes")
        }
    }
    
    // MARK: Regular search
    
    /// Search using the current request strategy to choose between online and offline (or a combination of both).
    @discardableResult @objc open override func search(_ query: Query, completionHandler: @escaping CompletionHandler) -> Operation {
        // IMPORTANT: A non-mirrored index must behave exactly as an online index.
        if (!mirrored) {
            return super.search(query, completionHandler: completionHandler);
        }
        // A mirrored index launches a mixed offline/online request.
        else {
            let queryCopy = Query(copy: query)
            let operation = OnlineOfflineSearchOperation(index: self, query: queryCopy, completionHandler: completionHandler)
            offlineClient.mixedRequestQueue.addOperation(operation)
            return operation
        }
    }
    
    fileprivate class OnlineOfflineSearchOperation: OnlineOfflineOperation {
        let query: Query
        
        init(index: MirroredIndex, query: Query, completionHandler: @escaping CompletionHandler) {
            self.query = query
            super.init(index: index, completionHandler: completionHandler)
        }
        
        override func startOnlineRequest(_ completionHandler: @escaping CompletionHandler) -> Operation {
            return index.searchOnline(query, completionHandler: completionHandler)
        }
        
        override func startOfflineRequest(_ completionHandler: @escaping CompletionHandler) -> Operation {
            return index.searchOffline(query, completionHandler: completionHandler)
        }
    }
    
    /// Explicitly search the online API, and not the local mirror.
    @discardableResult @objc open func searchOnline(_ query: Query, completionHandler: @escaping CompletionHandler) -> Operation {
        return super.search(query, completionHandler: {
            (content, error) in
            // Tag results as having a remote origin.
            var taggedContent: JSONObject? = content
            if taggedContent != nil {
                taggedContent?[MirroredIndex.JSONKeyOrigin] = MirroredIndex.JSONValueOriginRemote
            }
            completionHandler(taggedContent, error)
        })
    }
    
    /// Explicitly search the local mirror.
    @discardableResult @objc open func searchOffline(_ query: Query, completionHandler: @escaping CompletionHandler) -> Operation {
        assert(self.mirrored, "Mirroring not activated on this index")
        let queryCopy = Query(copy: query)
        let callingQueue = OperationQueue.current ?? OperationQueue.main
        let operation = BlockOperation()
        operation.addExecutionBlock() {
            let (content, error) = self._searchOffline(queryCopy)
            callingQueue.addOperation() {
                if !operation.isCancelled {
                    completionHandler(content, error)
                }
            }
        }
        self.offlineClient.searchQueue.addOperation(operation)
        return operation
    }

    /// Search the local mirror synchronously.
    fileprivate func _searchOffline(_ query: Query) -> (content: JSONObject?, error: NSError?) {
        assert(!Thread.isMainThread) // make sure it's run in the background
        
        var content: JSONObject?
        var error: NSError?
        
        let searchResults = localIndex.search(query.build())
        if searchResults.statusCode == 200 {
            assert(searchResults.data != nil)
            do {
                let json = try JSONSerialization.jsonObject(with: searchResults.data!, options: JSONSerialization.ReadingOptions(rawValue: 0))
                if json is JSONObject {
                    content = (json as! JSONObject)
                    // NOTE: Origin tagging performed by the SDK.
                } else {
                    error = NSError(domain: Client.ErrorDomain, code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON returned"])
                }
            } catch let _error as NSError {
                error = _error
            }
        } else {
            error = NSError(domain: Client.ErrorDomain, code: Int(searchResults.statusCode), userInfo: nil)
        }
        assert(content != nil || error != nil)
        return (content: content, error: error)
    }
    
    // MARK: Multiple queries
    
    /// Run multiple queries using the current request strategy to choose between online and offline.
    @discardableResult @objc override open func multipleQueries(_ queries: [Query], strategy: String?, completionHandler: @escaping CompletionHandler) -> Operation {
        // IMPORTANT: A non-mirrored index must behave exactly as an online index.
        if (!mirrored) {
            return super.multipleQueries(queries, strategy: strategy, completionHandler: completionHandler);
        }
        // A mirrored index launches a mixed offline/online request.
        else {
            let operation = OnlineOfflineMultipleQueriesOperation(index: self, queries: queries, completionHandler: completionHandler)
            offlineClient.mixedRequestQueue.addOperation(operation)
            return operation
        }
    }
    
    fileprivate class OnlineOfflineMultipleQueriesOperation: OnlineOfflineOperation {
        let queries: [Query]
        
        init(index: MirroredIndex, queries: [Query], completionHandler: @escaping CompletionHandler) {
            self.queries = queries
            super.init(index: index, completionHandler: completionHandler)
        }
        
        override func startOnlineRequest(_ completionHandler: @escaping CompletionHandler) -> Operation {
            return index.multipleQueriesOnline(queries, completionHandler: completionHandler)
        }
        
        override func startOfflineRequest(_ completionHandler: @escaping CompletionHandler) -> Operation {
            return index.multipleQueriesOffline(queries, completionHandler: completionHandler)
        }
    }
    
    /// Run multiple queries on the online API, and not the local mirror.
    @discardableResult @objc open func multipleQueriesOnline(_ queries: [Query], strategy: String?, completionHandler: @escaping CompletionHandler) -> Operation {
        return super.multipleQueries(queries, strategy: strategy, completionHandler: {
            (content, error) in
            // Tag results as having a remote origin.
            var taggedContent: JSONObject? = content
            if taggedContent != nil {
                taggedContent?[MirroredIndex.JSONKeyOrigin] = MirroredIndex.JSONValueOriginRemote
            }
            completionHandler(taggedContent, error)
        })
    }

    @discardableResult open func multipleQueriesOnline(_ queries: [Query], strategy: Client.MultipleQueriesStrategy? = nil, completionHandler: @escaping CompletionHandler) -> Operation {
        return self.multipleQueriesOnline(queries, strategy: strategy?.rawValue, completionHandler: completionHandler)
    }

    /// Run multiple queries on the local mirror.
    /// This method is the offline equivalent of `Index.multipleQueries()`.
    ///
    /// - parameter queries: List of queries.
    /// - parameter strategy: The strategy to use.
    /// - parameter completionHandler: Completion handler to be notified of the request's outcome.
    /// - returns: A cancellable operation.
    ///
    @discardableResult @objc open func multipleQueriesOffline(_ queries: [Query], strategy: String?, completionHandler: @escaping CompletionHandler) -> Operation {
        assert(self.mirrored, "Mirroring not activated on this index")
        
        // TODO: We should be doing a copy of the queries for better safety.
        let callingQueue = OperationQueue.current ?? OperationQueue.main
        let operation = BlockOperation()
        operation.addExecutionBlock() {
            let (content, error) = self._multipleQueriesOffline(queries, strategy: strategy)
            callingQueue.addOperation() {
                if !operation.isCancelled {
                    completionHandler(content, error)
                }
            }
        }
        self.offlineClient.searchQueue.addOperation(operation)
        return operation
    }
    
    @discardableResult open func multipleQueriesOffline(_ queries: [Query], strategy: Client.MultipleQueriesStrategy? = nil, completionHandler: @escaping CompletionHandler) -> Operation {
        return self.multipleQueriesOffline(queries, strategy: strategy?.rawValue, completionHandler: completionHandler)
    }
    
    /// Run multiple queries on the local mirror synchronously.
    fileprivate func _multipleQueriesOffline(_ queries: [Query], strategy: String?) -> (content: JSONObject?, error: NSError?) {
        // TODO: Should be moved to `LocalIndex` to factorize implementation between platforms.
        assert(!Thread.isMainThread) // make sure it's run in the background

        var content: JSONObject?
        var error: NSError?
        var results: [JSONObject] = []
        
        var shouldProcess = true
        for query in queries {
            // Implement the "stop if enough matches" strategy.
            if !shouldProcess {
                let returnedContent: JSONObject = [
                    "hits": [],
                    "page": 0,
                    "nbHits": 0,
                    "nbPages": 0,
                    "hitsPerPage": 0,
                    "processingTimeMS": 1,
                    "params": query.build(),
                    "index": self.indexName,
                    "processed": false
                ]
                results.append(returnedContent)
                continue
            }
            
            let (queryContent, queryError) = self._searchOffline(query)
            assert(queryContent != nil || queryError != nil)
            if queryError != nil {
                error = queryError
                break
            }
            var returnedContent = queryContent!
            returnedContent["index"] = self.indexName
            results.append(returnedContent)
            
            // Implement the "stop if enough matches strategy".
            if shouldProcess && strategy == Client.MultipleQueriesStrategy.StopIfEnoughMatches.rawValue {
                if let nbHits = returnedContent["nbHits"] as? Int, let hitsPerPage = returnedContent["hitsPerPage"] as? Int {
                    if nbHits >= hitsPerPage {
                        shouldProcess = false
                    }
                }
            }
        }
        if error == nil {
            content = [
                "results": results,
                // Tag results as having a local origin.
                // NOTE: Each individual result is also automatically tagged, but having a top-level key allows for
                // more uniform processing.
                MirroredIndex.JSONKeyOrigin: MirroredIndex.JSONValueOriginLocal
            ]
        }
        assert(content != nil || error != nil)
        return (content: content, error: error)
    }
    
    // ----------------------------------------------------------------------
    // MARK: - Browse
    // ----------------------------------------------------------------------
    // NOTE: Contrary to search, there is no point in transparently switching from online to offline when browsing,
    // as the results would likely be inconsistent. Anyway, the cursor is not portable across instances, so the
    // fall back could only work for the first query.

    /// Browse the local mirror (initial call).
    /// Same semantics as `Index.browse(...)`.
    ///
    @discardableResult @objc open func browseMirror(_ query: Query, completionHandler: @escaping CompletionHandler) -> Operation {
        assert(self.mirrored, "Mirroring not activated on this index")
        let queryCopy = Query(copy: query)
        let callingQueue = OperationQueue.current ?? OperationQueue.main
        let operation = BlockOperation()
        operation.addExecutionBlock() {
            let (content, error) = self._browseMirror(queryCopy)
            callingQueue.addOperation() {
                if !operation.isCancelled {
                    completionHandler(content, error)
                }
            }
        }
        self.offlineClient.searchQueue.addOperation(operation)
        return operation
    }

    /// Browse the index from a cursor.
    /// Same semantics as `Index.browseFrom(...)`.
    ///
    @discardableResult @objc open func browseMirrorFrom(_ cursor: String, completionHandler: @escaping CompletionHandler) -> Operation {
        assert(self.mirrored, "Mirroring not activated on this index")
        let callingQueue = OperationQueue.current ?? OperationQueue.main
        let operation = BlockOperation()
        operation.addExecutionBlock() {
            let query = Query(parameters: ["cursor": cursor])
            let (content, error) = self._browseMirror(query)
            callingQueue.addOperation() {
                if !operation.isCancelled {
                    completionHandler(content, error)
                }
            }
        }
        self.offlineClient.searchQueue.addOperation(operation)
        return operation
    }

    /// Browse the local mirror synchronously.
    fileprivate func _browseMirror(_ query: Query) -> (content: JSONObject?, error: NSError?) {
        assert(!Thread.isMainThread) // make sure it's run in the background
        
        var content: JSONObject?
        var error: NSError?
        
        let searchResults = localIndex.browse(query.build())
        // TODO: Factorize this code with above and with online requests.
        if searchResults.statusCode == 200 {
            assert(searchResults.data != nil)
            do {
                let json = try JSONSerialization.jsonObject(with: searchResults.data!, options: JSONSerialization.ReadingOptions(rawValue: 0))
                if json is JSONObject {
                    content = (json as! JSONObject)
                    // NOTE: Origin tagging performed by the SDK.
                } else {
                    error = NSError(domain: Client.ErrorDomain, code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON returned"])
                }
            } catch let _error as NSError {
                error = _error
            }
        } else {
            error = NSError(domain: Client.ErrorDomain, code: Int(searchResults.statusCode), userInfo: nil)
        }
        assert(content != nil || error != nil)
        return (content: content, error: error)
    }
}