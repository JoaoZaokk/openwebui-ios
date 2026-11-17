import Foundation

extension OpenWebUIClient {
    /// The models defined in the user's Workspace — what the web app's
    /// Workspace › Models page shows — as opposed to `models()`, which is every
    /// model the chat picker can use (each connection's raw list included).
    ///
    /// `GET /api/v1/models/list?page=N` answers `{items, total}`, 30 to a page,
    /// and only carries the user's own workspace models (or the ones shared with
    /// them). `ownedBy` holds the base model a workspace model sits on, which is
    /// what tells two similarly named ones apart.
    ///
    /// A server without that route (older, or a proxy that eats it) falls back to
    /// the full list, which is what the screen always showed.
    public func workspaceModels() async throws -> [OWModel] {
        struct Page: Decodable {
            var items: [Item]
            var total: Int?
            struct Item: Decodable {
                var id: String
                var name: String?
                var base_model_id: String?
            }
        }
        var all: [OWModel] = []
        var page = 1
        while page <= 50 {
            let data: Data
            do {
                data = try await send(request("/api/v1/models/list?page=\(page)"))
            } catch OWError.http(let code, _) where code == 404 || code == 405 {
                return page == 1 ? try await models() : all
            }
            guard let decoded = try? JSONDecoder().decode(Page.self, from: data) else {
                // A 200 that is not the JSON page — the web app's HTML shell, which
                // is what a server answers for a route it does not have.
                return page == 1 ? try await models() : all
            }
            all += decoded.items.map { OWModel(id: $0.id, name: $0.name ?? $0.id, ownedBy: $0.base_model_id) }
            if decoded.items.isEmpty || all.count >= (decoded.total ?? all.count) { break }
            page += 1
        }
        return all
    }
}
