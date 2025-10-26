import Foundation
import AppKit

class SecurityScopedResourceManager {
    static let shared = SecurityScopedResourceManager()
    
    private struct AccessedResource {
        let url: URL
        let accessTime: Date
        var isAccessing: Bool
    }
    
    private var accessedResources: [URL: AccessedResource] = [:]
    private let accessQueue = DispatchQueue(label: "com.multiscan.resourceaccess")
    private let maxAccessDuration: TimeInterval = 300 // 5 minutes
    private var cleanupTimer: Timer?
    
    private init() {
        setupCleanupTimer()
    }
    
    private func setupCleanupTimer() {
        DispatchQueue.main.async {
            self.cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                self.cleanupStaleAccess()
            }
        }
    }
    
    private func cleanupStaleAccess() {
        accessQueue.async {
            let now = Date()
            var urlsToStop: [URL] = []
            
            for (url, resource) in self.accessedResources {
                if resource.isAccessing && now.timeIntervalSince(resource.accessTime) > self.maxAccessDuration {
                    urlsToStop.append(url)
                }
            }
            
            for url in urlsToStop {
                self.stopAccessingURL(url)
            }
        }
    }
    
    func withSecurityScopedAccess<T>(to url: URL, bookmarkData: Data? = nil, perform: (URL) throws -> T) throws -> T {
        var effectiveURL = url
        
        // If we have bookmark data, resolve it first
        if let bookmarkData = bookmarkData {
            var isStale = false
            effectiveURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                print("Warning: Bookmark is stale for URL: \(url)")
            }
        }
        
        // Check if we already have access
        var needsNewAccess = true
        accessQueue.sync {
            if let resource = accessedResources[effectiveURL], resource.isAccessing {
                // Update access time to keep it fresh
                accessedResources[effectiveURL] = AccessedResource(url: effectiveURL, accessTime: Date(), isAccessing: true)
                needsNewAccess = false
            }
        }
        
        // Start new access if needed
        if needsNewAccess {
            let accessed = effectiveURL.startAccessingSecurityScopedResource()
            if accessed {
                accessQueue.sync {
                    accessedResources[effectiveURL] = AccessedResource(url: effectiveURL, accessTime: Date(), isAccessing: true)
                }
            } else {
                throw SecurityScopedError.accessDenied
            }
        }
        
        // Perform the operation
        do {
            return try perform(effectiveURL)
        } catch {
            // If the operation fails, try to refresh access once
            stopAccessingURL(effectiveURL)
            
            let accessed = effectiveURL.startAccessingSecurityScopedResource()
            if accessed {
                accessQueue.sync {
                    accessedResources[effectiveURL] = AccessedResource(url: effectiveURL, accessTime: Date(), isAccessing: true)
                }
                return try perform(effectiveURL)
            } else {
                throw error
            }
        }
    }
    
    private func stopAccessingURL(_ url: URL) {
        accessQueue.sync {
            if let resource = accessedResources[url], resource.isAccessing {
                url.stopAccessingSecurityScopedResource()
                accessedResources[url] = AccessedResource(url: url, accessTime: resource.accessTime, isAccessing: false)
            }
        }
    }
    
    func stopAccessingAllURLs() {
        accessQueue.sync {
            for (url, resource) in accessedResources where resource.isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            accessedResources.removeAll()
        }
    }
    
    func createBookmark(for url: URL) -> Data? {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return bookmarkData
        } catch {
            print("Error creating bookmark: \(error)")
            return nil
        }
    }
    
    deinit {
        DispatchQueue.main.async { [weak cleanupTimer] in
            cleanupTimer?.invalidate()
        }
        stopAccessingAllURLs()
    }
}

enum SecurityScopedError: LocalizedError {
    case accessDenied
    
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Could not access the security-scoped resource"
        }
    }
}
