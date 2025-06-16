import Foundation
import AppKit

class SecurityScopedResourceManager {
    static let shared = SecurityScopedResourceManager()
    private var accessedURLs: Set<URL> = []
    
    private init() {}
    
    func accessSecurityScopedURL(_ url: URL) -> Bool {
        if url.startAccessingSecurityScopedResource() {
            accessedURLs.insert(url)
            return true
        }
        return false
    }
    
    func stopAccessingSecurityScopedURL(_ url: URL) {
        if accessedURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
            accessedURLs.remove(url)
        }
    }
    
    func stopAccessingAllURLs() {
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()
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
    
    func loadImage(from url: URL) -> NSImage? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        return NSImage(contentsOf: url)
    }
    
    deinit {
        stopAccessingAllURLs()
    }
}
