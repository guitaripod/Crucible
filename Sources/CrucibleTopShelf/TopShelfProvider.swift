import TVServices

open class TopShelfProvider: TVTopShelfContentProvider {
    open override func loadTopShelfContent(completionHandler: @escaping @Sendable ((any TVTopShelfContent)?) -> Void) {
        completionHandler(TVTopShelfSectionedContent(sections: []))
    }
}
