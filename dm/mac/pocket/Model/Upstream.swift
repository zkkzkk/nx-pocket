// How this checkout stands against upstream nxnative (Settings: its address and branch, seedds/nxnative's main by default): its new commits are fetched (git fetch into
// FETCH_HEAD: no branch, remote or ref is made or moved, and nothing is merged), counted both ways, listed, and what they change is matched against each game's pack
// (PackAge's parts): which packs would be out of date once they are merged. Merging stays the player's to do in the checkout. Checked on request and once a day.
import Foundation

struct UpstreamCommit: Identifiable, Equatable { let id: String; let date: String; let author: String; let subject: String }

struct UpstreamReport: Equatable {
    let head: String              // upstream's commit fetched
    let behind: Int               // its commits this checkout has not
    let ahead: Int                // this checkout's that it has not
    let commits: [UpstreamCommit] // the newest of the behind ones
    let files: [String]           // what they change, since the two parted
    let checked: Date
}

@MainActor final class Upstream: ObservableObject {
    enum State: Equatable { case idle, checking, done(UpstreamReport), failed(String) }
    @Published private(set) var state: State = .idle
    @Published var showWindow = false
    var url: String { UserDefaults.standard.string(forKey: "upstreamURL").flatMap { $0.isEmpty ? nil : $0 } ?? "https://github.com/seedds/nxnative" }
    var branch: String { UserDefaults.standard.string(forKey: "upstreamBranch").flatMap { $0.isEmpty ? nil : $0 } ?? "main" }
    var report: UpstreamReport? { if case .done(let r) = state { r } else { nil } }

    func start(repo: String) {
        let last = UserDefaults.standard.double(forKey: "upstreamChecked")
        if !repo.isEmpty, Date().timeIntervalSince1970 - last > 86_400 { Task { await check(repo: repo) } }
    }

    func check(repo: String) async {
        guard !repo.isEmpty else { state = .failed(tr("No nxnative checkout is set.")); return }
        state = .checking
        let (u, b) = (url, branch)
        let result: Result<UpstreamReport, Error> = await Task.detached {
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let git = "git -C \(q(repo))"
            let fetched = Setup.sh("\(git) fetch --quiet --no-tags \(q(u)) \(q(b)) 2>&1 && echo ok")
            guard fetched.hasSuffix("ok") else { return .failure(NSError(domain: "upstream", code: 1, userInfo: [NSLocalizedDescriptionKey: fetched.isEmpty ? tr("git fetch failed") : fetched])) }
            let head = Setup.sh("\(git) rev-parse FETCH_HEAD")
            let behind = Int(Setup.sh("\(git) rev-list --count HEAD..\(head)")) ?? 0
            let ahead = Int(Setup.sh("\(git) rev-list --count \(head)..HEAD")) ?? 0
            let commits = Setup.sh("\(git) log -n 200 --format='%h%x09%as%x09%an%x09%s' HEAD..\(head)").split(separator: "\n").compactMap { line -> UpstreamCommit? in
                let f = line.split(separator: "\t", maxSplits: 3).map(String.init)
                return f.count == 4 ? UpstreamCommit(id: f[0], date: f[1], author: f[2], subject: f[3]) : nil
            }
            let files = Setup.sh("\(git) diff --name-only HEAD...\(head)").split(separator: "\n").map(String.init)   // upstream's side since the two parted
            return .success(UpstreamReport(head: head, behind: behind, ahead: ahead, commits: commits, files: files, checked: Date()))
        }.value
        switch result {
        case .success(let r): state = .done(r); UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "upstreamChecked")
        case .failure(let e): state = .failed(String(format: tr("Could not reach upstream: %@"), e.localizedDescription))
        }
    }

    /// What merging upstream would put out of date in a game's pack: the parts of it (PackAge.parts) its new commits change
    func wouldChange(_ g: MacGame) -> [String] {
        guard let r = report, g.pack != nil, r.behind > 0 else { return [] }
        return PackAge.parts(g.titleID).filter { _, inPart in r.files.contains(where: inPart) }.map(\.0)
    }
}
